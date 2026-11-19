# frozen_string_literal: true

require "fileutils"
require "optparse"
require "yaml"
require "graphql/schema_change"

module GraphQL
  module SchemaChange
    class CLI
      COMMANDS = %w[check init changes explain version].freeze

      def self.run(argv, stdout: $stdout, stderr: $stderr, stdin: $stdin)
        new(stdout, stderr, stdin).run(argv)
      end

      def initialize(stdout, stderr, stdin)
        @stdout, @stderr, @stdin = stdout, stderr, stdin
        @options = {}
      end

      def run(argv)
        arguments = argv.dup
        first_argument = arguments.first
        command = COMMANDS.include?(first_argument) ? arguments.shift : "check"
        parser.parse!(arguments)
        return 0 if @help

        command = "version" if @version
        if command != "explain" && !arguments.empty?
          raise OptionParser::InvalidArgument, arguments.join(" ")
        end

        case command
        when "check" then check
        when "init" then init
        when "changes" then changes
        when "explain" then explain(arguments)
        when "version" then version
        end
        command == "check" ? @exit_status : 0
      rescue OptionParser::ParseError, LintCore::InputError, SystemCallError, IOError => error
        log_stderr(error.message)
        2
      rescue StandardError => error
        log_stderr("Internal error in graphql-schema-change: #{error.message}. Please report this issue.")
        log_stderr(error.full_message) if @options["debug"]
        3
      end

      private

      def parser
        OptionParser.new do |option|
          option.banner = "Usage: graphql-schema-change [#{COMMANDS.join('|')}] [options]"
          option.on("--old SOURCE", "Schema before the change") { |source| append("old", source) }
          option.on("--new SOURCE", "Schema after the change") { |source| append("new", source) }
          option.on("--documents GLOB", "Known operation documents") { |glob| append("documents", glob) }
          option.on("-c", "--config PATH", "Configuration file") { |path| @config = path }
          option.on("-f", "--format NAME[:PATH]", "Output format (repeatable)") { |format| append("format", format) }
          option.on("-r", "--require PATH", "Load a Ruby extension") { |path| append("require", path) }
          option.on("--emit-generated-sdl PATH", "Save generated SDL for the new schema") { |path| @emit_path = path }
          option.on("--no-color", "Disable ANSI colors") { @options["no_color"] = true }
          option.on("-q", "--quiet", "Show errors only") { @options["quiet"] = true }
          option.on("--debug", "Print unexpected exception backtraces") { @options["debug"] = true }
          option.on("-h", "--help", "Show help") { @help = true; @stdout.puts(option) }
          option.on("--version", "Show versions") { @version = true }
        end
      end

      def append(key, value)
        (@options[key] ||= []) << value
      end

      def check
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @emit_path
          if @options.key?("new")
            @options["new"] = {"sources" => @options["new"], "emit_generated_sdl" => @emit_path}
          else
            settings = LintCore::Config.load(@config, defaults: Runner::DEFAULTS, filename: Runner::CONFIG_FILENAME,
              disallow: Runner::UNSUPPORTED)
            sources = settings["new"]
            @options["new"] = if sources.is_a?(Hash) && sources.key?("sources")
              sources.merge("emit_generated_sdl" => @emit_path)
            else
              {"sources" => sources, "emit_generated_sdl" => @emit_path}
            end
          end
        end
        result = Runner.new(stdin: @stdin).run(config: @config, overrides: @options)
        @exit_status = result.exit_status
        fallback = @stdout.respond_to?(:tty?) && @stdout.tty? ? "text" : "compact"
        formats = Array(result.config["format"] || @options["format"] || fallback)
        @github_output = github_format?(formats)
        formats.each do |entry|
          format, path = entry.split(":", 2)
          unless LintCore::Config::FORMATS.include?(format)
            format, path = fallback, nil
          end
          rendered = result.render(format)
          if path
            FileUtils.mkdir_p(File.dirname(path))
            File.binwrite(path, rendered)
          else
            @stdout.write(rendered)
          end
          if format == "github" && (summary = ENV["GITHUB_STEP_SUMMARY"]) && !summary.empty?
            File.open(summary, "a") { |file| file.write(result.render("markdown")) }
          end
        end
        result.diagnostics.each do |diagnostic|
          log_stderr(diagnostic.message) if diagnostic.fatal? || diagnostic.rule_id == "core/skipped-schema-check"
        end
        if @options["debug"] || result.config["debug"]
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          log_stderr(format("graphql-schema-change completed in %.3f seconds.", elapsed))
          log_stderr(result.internal_error.full_message) if result.internal_error
        end
      end

      def github_format?(formats)
        Array(formats).any? { |entry| entry.split(":", 2).first == "github" }
      end

      def log_stderr(message)
        github = @github_output || ENV["GITHUB_ACTIONS"] == "true" || github_format?(@options["format"])
        @stderr.puts(LintCore::Formatter.log_message(message, github: github))
      end

      def changes
        Catalog::ENTRIES.each do |id, entry|
          @stdout.puts("#{id}\t#{entry.classification}#{' (conditional)' if entry.conditional}")
        end
      end

      def explain(args)
        unless args.size == 1 && Catalog::ENTRIES.key?(args.first)
          raise LintCore::InputError, "Provide a known change ID. Run graphql-schema-change changes to see the list."
        end

        if @config
          LintCore::Config.load(@config, defaults: Runner::DEFAULTS, filename: Runner::CONFIG_FILENAME,
            overrides: @options, disallow: Runner::UNSUPPORTED)
        end

        id = args.first
        entry = Catalog::ENTRIES.fetch(id)
        @stdout.puts(id, "Default classification: #{entry.classification}", Catalog.reason(id))
        @stdout.puts("The schema and policy can change the classification.") if entry.conditional
      end

      def init
        path = @config || Runner::CONFIG_FILENAME
        File.open(path, File::WRONLY | File::CREAT | File::EXCL) do |file|
          file.write(YAML.dump("version" => 1, "old" => "git:HEAD:schema.graphql", "new" => "schema.graphql"))
        end
        @stdout.puts(path)
      rescue Errno::EEXIST
        raise LintCore::InputError, "#{path} already exists."
      end

      def version
        @stdout.puts("graphql-schema_change #{VERSION}", "graphql-lint_core #{LintCore::VERSION}",
          "graphql #{GraphQL::VERSION}", "Ruby #{RUBY_VERSION}")
      end
    end
  end
end
