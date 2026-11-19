# frozen_string_literal: true

module GraphQL
  module SchemaChange
    # @api public
    class Result
      TOOL = "graphql-schema_change"
      MARKDOWN_LIMIT = 60_000
      HEADINGS = {breaking: "Breaking changes", dangerous: "Dangerous changes", safe: "Safe changes"}.freeze

      attr_reader :changes, :broken_operations, :documents, :diagnostics, :exit_status,
        :closed_world, :config, :internal_error

      def initialize(exit_status:, diagnostics:, config:, old_schema:, new_schema:,
        changes: [], broken_operations: [], documents: {count: 0, invalid_before: 0},
        report_safe: true, closed_world: nil, documents_given: false, internal_error: nil)
        @changes, @exit_status, @diagnostics, @config = changes, exit_status, diagnostics, config
        @broken_operations, @documents, @documents_given = broken_operations, documents, documents_given
        @old_schema, @new_schema = old_schema, new_schema
        @closed_world, @report_safe, @internal_error = closed_world, report_safe, internal_error
      end

      def fatal? = exit_status >= 2
      def reportable = diagnostics
      def stats = summary

      def to_h
        {
          format_version: 1, tool: {name: TOOL, version: VERSION},
          old: {sources: source_paths(@old_schema)}, new: {sources: source_paths(@new_schema)},
          documents: documents, closed_world: closed_world, summary: summary,
          changes: visible_changes(include_safe: true).map(&:to_h), broken_operations: broken_operations,
          policy_diagnostics: diagnostics.select { |diagnostic| diagnostic.rule_id.start_with?("policy/") }.map(&:to_h),
          diagnostics: diagnostics.map(&:to_h)
        }
      end

      def to_json(*options)
        to_h.to_json(*options)
      end

      def render(format)
        case format
        when "json" then JSON.pretty_generate(to_h) + "\n"
        when "text" then render_text
        when "markdown" then render_markdown
        else LintCore::Formatter.render(format, diagnostic_result, quiet: config["quiet"])
        end
      end

      private

      def summary
        classifications = visible_changes(include_safe: true).group_by(&:classification)
        Policy::CLASSIFICATIONS.to_h { |item| [item, classifications.fetch(item, []).size] }.merge(
          broken_operations: broken_operations.size, result: exit_status.zero? ? :pass : :fail, exit_status: exit_status)
      end

      def display_changes
        items = visible_changes
        config["quiet"] ? items.select { |change| change.policy[:result] == :fail } : items
      end

      def display_diagnostics
        config["quiet"] ? diagnostics.select { |diagnostic| diagnostic.severity == :error } : diagnostics
      end

      def visible_changes(include_safe: @report_safe)
        changes.reject { |change| change.policy[:result] == :ignored || (!include_safe && change.classification == :safe) }
      end

      def source_paths(schema)
        Array(schema&.sources).reject(&:prelude?).map(&:path)
      end

      def render_text
        lines = []
        lines << "Closed world: #{closed_world}" if closed_world
        lines << "Before: #{source_paths(@old_schema).join(', ')}" if @old_schema
        lines << "After: #{source_paths(@new_schema).join(', ')}" if @new_schema
        lines << "Known operations: #{documents[:count]} (#{documents[:invalid_before]} already invalid)"

        display_changes.group_by(&:classification).sort_by { |classification, _| Policy::CLASSIFICATIONS.index(classification) }.each do |classification, changes|
          lines << "" << "#{HEADINGS.fetch(classification)} (#{changes.size})"
          changes.each do |change|
            lines << "  #{change.type} #{subject(change)}#{values(change)}"
            lines << "    #{change.reason}#{impact_label(change)}"
            if (location = change.new_location || change.old_location)
              lines << "    #{[location.path, location.line, location.column].compact.join(':')}"
            end
            if change.policy[:result] == :allowed || change.policy[:matched] == "policy_hook"
              lines << "    #{[change.policy[:matched], change.policy[:reason]].compact.join(': ')}"
            end
            next if change.classification == :safe && change.type != "DEPRECATION_ADDED"

            names = operation_names(change)
            lines << "    #{names.empty? ? no_references : names.join(', ')}"
          end
        end
        lines << "" << "Broken known operations: #{broken_operations.size}"
        broken_operations.each do |operation|
          lines << "  #{operation.fetch(:operation)}"
          lines << "    A responsible change could not be identified for every error." if operation[:unattributed]
          lines.concat(operation.fetch(:errors).map { |error| "    #{error.fetch(:message)}" })
        end
        unless config["quiet"]
          lines.concat(operation_status("Already invalid", documents[:invalid_before_operations]))
          lines.concat(operation_status("Newly valid", documents[:newly_valid]))
          lines.concat(operation_status("Unverified", documents[:unverified]))
        end
        display_diagnostics.each { |diagnostic| lines << "#{diagnostic.severity} [#{diagnostic.rule_id}] #{diagnostic.message}" }
        lines << "" << "Result: #{exit_status.zero? ? 'pass' : 'fail'}"
        lines.join("\n") + "\n"
      end

      def operation_status(label, entries)
        return [] if entries.nil? || entries.empty?

        ["#{label}: #{entries.map { |entry| entry.fetch(:operation) }.join(', ')}"]
      end

      def render_markdown
        report = ["## GraphQL schema changes · #{exit_status.zero? ? 'Pass' : 'Fail'}", ""]
        report << "Closed world: #{markdown(locally_bounded(closed_world, 4_096))}\n" if closed_world
        counts = summary
        report.concat(["| Classification | Count |", "|---|---:|"])
        Policy::CLASSIFICATIONS.each { |classification| report << "| #{HEADINGS.fetch(classification)} | #{counts.fetch(classification)} |" }
        report << "| Broken known operations | #{broken_operations.size} |" << ""

        grouped = display_changes.group_by(&:classification)
        omissions = {changes: 0, entries: 0}
        remaining = MARKDOWN_LIMIT - 200 - report.sum { |line| line.bytesize + 1 }
        append = lambda do |*lines|
          bytes = lines.sum { |line| line.bytesize + 1 }
          next false if bytes > remaining

          report.concat(lines)
          remaining -= bytes
          true
        end

        Policy::CLASSIFICATIONS.each do |classification|
          if classification == :safe
            broken_operations.each do |operation|
              hint = operation[:errors].map { |error| markdown(locally_bounded(error[:message], 2_048)) }.join(" · ")
              omissions[:entries] += 1 unless append.call("- **#{markdown(operation[:operation])}** #{hint}")
            end
            display_diagnostics.each do |diagnostic|
              detail = markdown(locally_bounded(diagnostic.message, 2_048))
              omissions[:entries] += 1 unless append.call("- **#{markdown(diagnostic.rule_id)}** #{detail}")
            end
          end
          items = grouped.fetch(classification, [])
          next if items.empty?

          heading = HEADINGS.fetch(classification)
          open, close = classification == :safe ? ["<details><summary>#{heading}</summary>", "</details>"] : ["### #{heading}", ""]
          header = "| Change | Coordinate | Values | Reason | Operations |"
          if remaining < open.bytesize + close.bytesize + header.bytesize + 40
            omissions[:changes] += items.size
            next
          end

          append.call("", open, "", header, "|---|---|---|---|---|")
          reservation = close.empty? ? 0 : close.bytesize + 2
          remaining -= reservation
          items.each { |change| omissions[:changes] += 1 unless append.call(markdown_row(change)) }
          remaining += reservation
          append.call("", close) unless close.empty?
        end

        changes, entries = omissions.values_at(:changes, :entries)
        if changes.positive? || entries.positive?
          report << "" << "#{changes} changes and #{entries} diagnostics or operations omitted."
        end
        report.join("\n") + "\n"
      end

      def markdown_row(change)
        names = operation_names(change)
        names << no_references if names.empty? && change.classification != :safe
        reason = [change.reason, impact_label(change).strip, change.policy[:reason]].compact.join(" ")
        "| #{markdown(change.type)} | #{markdown(subject(change))} | #{markdown(values(change).strip)} | #{markdown(reason)} | #{markdown(names.join(', '))} |"
      end

      def diagnostic_result
        entries = visible_changes.map do |change|
          severity = {fail: :error, warn: :warning}.fetch(change.policy[:result], :info)
          message = [subject(change), change.reason, change.policy[:reason]].compact.join(" ")
          location = change.new_location || change.old_location
          if location && !change.new_location && old_git_source?(location)
            target = change.coordinate || change.subject&.[](:target)
            owner = target&.split(/[.(]/, 2)&.first
            location = @new_schema&.index&.find(owner)&.location || @new_schema&.index&.schema_location
            message += " Original location: #{change.old_location.path}:#{change.old_location.line}."
          end
          LintCore::Diagnostic.new(rule_id: "change/#{change.type}", severity: severity,
            location: location, message: message, coordinate: change.coordinate, subject: change.subject, data: change.to_h)
        end
        LintCore::Result.new(diagnostics: entries + diagnostics, tool: TOOL, version: VERSION, config: config, exit_status: exit_status)
      end

      def old_git_source?(location)
        @old_schema&.sources&.any? { |source| source.path == location.path && source.kind == :git }
      end

      def subject(change)
        change.coordinate || change.subject&.[](:target) || "schema"
      end

      def values(change)
        return "" if change.old_value.nil? && change.new_value.nil?

        "  #{change.old_value.nil? ? '∅' : change.old_value} → #{change.new_value.nil? ? '∅' : change.new_value}"
      end

      def impact_label(change)
        return "" if change.impacts.empty?

        " (impact: #{change.impacts.join(', ')})"
      end

      def operation_names(change)
        change.related_operations.map do |operation|
          certainty = case operation.fetch(:match)
          when "type_level" then " (type-level)"
          when "return_type" then " (return type)"
          else ""
          end
          "#{operation.fetch(:operation)}#{certainty}"
        end.uniq
      end

      def no_references
        if @documents_given
          "No known operation references this change. Other clients were not evaluated."
        else
          "No known operations were provided."
        end
      end

      def locally_bounded(value, limit)
        value.bytesize > limit ? "#{value.byteslice(0, limit).scrub('')}…" : value
      end

      def markdown(value)
        value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub(/[\r\n]+/, " ")
          .gsub(/[\\|`*_~\[\]#!]/) { |character| "\\#{character}" }
      end
    end
  end
end
