# frozen_string_literal: true

module GraphQL
  module SchemaChange
    class Runner
      DEFAULTS = {"version" => 1, "old" => nil, "new" => nil, "documents" => nil, "policy" => {}, "today" => nil}.freeze
      UNSUPPORTED = %w[rules ignore baseline].freeze
      CONFIG_FILENAME = ".graphql-schema-change.yml"

      def initialize(stdin: $stdin)
        @stdin = stdin
      end

      def run(config:, overrides:)
        settings = LintCore::Config.load(config, defaults: DEFAULTS, overrides: overrides, filename: CONFIG_FILENAME,
          disallow: UNSUPPORTED)
        @settings = settings
        policy = Policy.new(settings.fetch("policy"), today: settings["today"])
        LintCore::Config.require_extensions(settings)
        @old_schema = load_schema(settings.fetch("old"), "old")
        @new_schema = load_schema(settings.fetch("new"), "new")
        diagnostics = @old_schema.diagnostics + @new_schema.diagnostics
        return result(diagnostics: diagnostics, exit_status: 2) if @old_schema.fatal? || @new_schema.fatal?

        changes = Diff.new(@old_schema.index, @new_schema.index, policy).compare
        documents = document_set(settings["documents"])
        impact = Impact.new(documents, @old_schema, @new_schema)
        impact.compare(changes)
        failed = policy.evaluate(changes, impact.broken, valid_operations: impact.valid_before,
          complete_corpus: impact.complete?, hooks: SchemaChange.policy_hooks)
        result(changes: changes, broken_operations: impact.broken.map { |entry| entry.reject { |key, _| key == :causes } },
          documents: impact.statistics, diagnostics: (diagnostics + impact.diagnostics + policy.diagnostics).uniq(&:sort_key),
          report_safe: policy.report_safe?, closed_world: policy.closed_world_statement,
          documents_given: !settings["documents"].nil?, exit_status: failed ? 1 : 0)
      rescue LintCore::InputError, SystemCallError => error
        result(diagnostics: [LintCore::Diagnostic.new(rule_id: "core/config-error",
          severity: :error, message: error.message, fatal: true)], exit_status: 2)
      rescue StandardError => error
        message = "Internal error: #{error.message}. Please report this issue with graphql-schema_change #{VERSION}, " \
          "graphql-lint_core #{LintCore::VERSION}, graphql #{GraphQL::VERSION}, and Ruby #{RUBY_VERSION}."
        result(diagnostics: [LintCore::Diagnostic.new(rule_id: "core/internal-error",
          severity: :error, message: message, fatal: true)], exit_status: 3, internal_error: error)
      end

      private

      def result(**values)
        Result.new(**values, config: @settings || {}, old_schema: @old_schema, new_schema: @new_schema)
      end

      def load_schema(input, name)
        loader_options = {stdin: @stdin, repository: @settings.dig("git", "repository")}
        if input.is_a?(Hash) && (input.key?("sources") || input.key?("prelude") || input.key?("skip_checks") || input.key?("emit_generated_sdl"))
          unknown = input.keys - %w[sources prelude skip_checks emit_generated_sdl]
          raise LintCore::ConfigError, "Unknown setting #{name}.#{unknown.first}." unless unknown.empty?

          source = input["sources"]
          prelude = input.fetch("prelude", [])
          skip_checks = input.fetch("skip_checks", [])
          LintCore::SchemaLoader.load(source, prelude: prelude, skip_checks: skip_checks,
            emit_generated_sdl: input["emit_generated_sdl"], **loader_options)
        else
          LintCore::SchemaLoader.load(input, **loader_options)
        end
      end

      def document_set(input)
        options = case input
        when nil
          {"include" => []}
        when Array, String
          {"include" => Array(input)}
        when Hash
          input
        else
          raise LintCore::ConfigError, "documents must be a path, list of paths, or mapping."
        end
        if input.is_a?(Hash) && (unknown = options.keys - %w[include exclude fragment_resolution]).any?
          raise LintCore::ConfigError, "Unknown setting documents.#{unknown.first}."
        end

        include_paths = options.fetch("include", [])
        exclude_paths = options.fetch("exclude", [])
        {include: include_paths, exclude: exclude_paths}.each do |key, paths|
          unless paths.is_a?(Array) && paths.all? { |path| path.is_a?(String) && !path.empty? }
            raise LintCore::ConfigError, "documents.#{key} must be an array of non-empty paths."
          end
        end
        source = LintCore::Documents::FileSource.new(include: include_paths, exclude: exclude_paths)
        LintCore::Documents::DocumentSet.new(source, fragment_resolution: options.fetch("fragment_resolution", "global"))
      end
    end
  end
end
