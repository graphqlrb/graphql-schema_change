# frozen_string_literal: true

require "date"

module GraphQL
  module SchemaChange
    class Policy
      CLASSIFICATIONS = %i[breaking dangerous safe].freeze
      IMPACTS = %i[request response behavior].freeze
      DEFAULTS = {
        "fail_on" => ["breaking"],
        "warn_on" => ["dangerous"],
        "fail_on_broken_operations" => true,
        "unreachable" => "downgrade",
        "classification_profile" => "standard",
        "allow_removal_of_deprecated" => false,
        "overrides" => [],
        "applied_directives" => {},
        "allow" => [],
        "closed_world" => {},
        "report_safe" => true
      }.freeze

      Rule = Data.define(:change, :coordinate, :impacts, :classification, :reason, :expires) do
        def matches?(item)
          File.fnmatch?(change, item.type) &&
            (!coordinate || coordinate.match?(item.coordinate || item.subject&.[](:target))) &&
            (!impacts || impacts.sort == item.impacts.sort)
        end
      end

      attr_reader :today, :diagnostics, :tracked_directives, :applied_classification, :closed_world_statement

      def initialize(settings, today:, locale:)
        @options = DEFAULTS.merge(mapping(settings, "policy", DEFAULTS.keys))
        @today = date(today || ENV["GRAPHQL_LINT_TODAY"] || Date.today, "today")
        @locale = locale
        @diagnostics = []
        @fail_on = choices(@options.fetch("fail_on"), "policy.fail_on", CLASSIFICATIONS)
        @warn_on = choices(@options.fetch("warn_on"), "policy.warn_on", CLASSIFICATIONS)
        @broken = choice(@options.fetch("fail_on_broken_operations"), "policy.fail_on_broken_operations", [true, false, "always"])
        @unreachable = choice(@options.fetch("unreachable"), "policy.unreachable", %w[downgrade keep])
        @profile = choice(@options.fetch("classification_profile"), "policy.classification_profile", %w[standard conservative])
        @report_safe = choice(@options.fetch("report_safe"), "policy.report_safe", [true, false])
        @allow_deprecated = deprecated_setting(@options.fetch("allow_removal_of_deprecated"))
        @overrides = array(@options.fetch("overrides"), "policy.overrides").map { |rule| override(rule) }
        @allows = array(@options.fetch("allow"), "policy.allow").map { |rule| allowance(rule) }
        @used_allows = {}.compare_by_identity
        read_applied_directives(@options.fetch("applied_directives"))
        read_closed_world(@options.fetch("closed_world"))
      end

      def conservative? = @profile == "conservative"
      def downgrade_unreachable? = @unreachable == "downgrade"
      def report_safe? = @report_safe

      def evaluate(changes, broken, valid_operations:, complete_corpus:, hooks: [])
        context = {today: today, valid_operations: valid_operations, broken_operations: broken,
          complete_corpus: complete_corpus}.freeze
        if closed_world_statement && valid_operations.zero?
          diagnostic("empty-closed-world", :warning,
            localized("The closed-world policy requires at least one valid known operation.",
              "閉じた利用者集合を使うには、妥当な既知 Operation が1件以上必要です。"))
        elsif closed_world_statement && !complete_corpus
          diagnostic("incomplete-closed-world", :warning,
            localized("Some known documents could not be checked. The closed-world policy did not lower classifications.",
              "検証できなかった既知文書があるため、閉じた利用者集合による分類の引き下げは行いません。"))
        end
        @allows.each do |allow|
          next unless expired?(allow)

          diagnostic("expired-allow", :error, localized(
            "The allowance for #{allow.change} expired on #{allow.expires}.",
            "#{allow.change} の許可は #{allow.expires} に期限切れになりました。"))
        end
        changes.each { |change| evaluate_change(change, context, hooks) }
        @allows.each do |allow|
          next if @used_allows[allow] || expired?(allow)

          diagnostic("unused-allow", :info, localized(
            "The allowance for #{allow.change} did not match a change.",
            "#{allow.change} の許可に該当する変更がありませんでした。"))
        end

        changes.any? { |change| change.policy[:result] == :fail } ||
          diagnostics.any? { |item| item.severity == :error } || broken_failure?(broken)
      end

      private

      def evaluate_change(change, context, hooks)
        if (override = @overrides.reverse_each.find { |rule| rule.matches?(change) })
          return change.policy = {result: :ignored, matched: "overrides: #{override.change}"} if override.classification == :ignore

          change.reclassify(override.classification, reason: change.reason)
        end

        original = change.classification
        hooks.each { |hook| hook.call(change, context) }
        matched = if original != change.classification
          "policy_hook"
        elsif override
          "overrides: #{override.change}"
        end

        if deprecated_removal_allowed?(change)
          return change.policy = {result: :allowed, matched: "allow_removal_of_deprecated", reason: change.deprecation.reason}
        end

        if closed_world_statement && context.fetch(:complete_corpus) && context.fetch(:valid_operations).positive? &&
            context.fetch(:broken_operations).empty? &&
            change.breaking? && change.related_operations.empty?
          reason = Catalog.reason("closed_world_unreferenced", @locale)
          change.reclassify(:dangerous, reason: "#{change.reason} #{reason}")
          matched = "closed_world"
        end

        allowances = @allows.reject { |rule| expired?(rule) }.select { |rule| rule.matches?(change) }
        allowances.each { |rule| @used_allows[rule] = true }
        if (allow = allowances.last)
          return change.policy = {result: :allowed, matched: "allow: #{allow.change}", reason: allow.reason}
        end

        classification = change.classification
        result, threshold = if @fail_on.include?(classification)
          [:fail, "fail_on: #{classification}"]
        elsif @warn_on.include?(classification)
          [:warn, "warn_on: #{classification}"]
        else
          [:pass, nil]
        end
        change.policy = {result: result, matched: matched || threshold}.compact
      end

      def deprecated_removal_allowed?(change)
        return false unless @allow_deprecated && change.type.end_with?("_REMOVED") && change.deprecation
        return true if @allow_deprecated == true

        raw_date = change.deprecation.reason.to_s[/\d{4}-\d{2}-\d{2}/]
        raw_date && (today - Date.iso8601(raw_date)) >= @allow_deprecated
      rescue Date::Error
        false
      end

      def expired?(allow)
        allow.expires && allow.expires < today
      end

      def broken_failure?(broken)
        return false if @broken == false
        return !broken.empty? if @broken == "always"

        broken.any? do |entry|
          causes = entry.fetch(:causes)
          entry.fetch(:unattributed) || causes.any? { |change| !%i[allowed ignored].include?(change.policy[:result]) }
        end
      end

      def read_applied_directives(options)
        entries = mapping(options, "policy.applied_directives", %w[track classification])
        @tracked_directives = array(entries.fetch("track", []), "policy.applied_directives.track").map do |name|
          unless name.is_a?(String) && name.match?(/\A[_A-Za-z][_0-9A-Za-z]*\z/)
            raise LintCore::ConfigError, "policy.applied_directives.track must contain directive names."
          end

          name
        end.uniq
        @applied_classification = choice(entries.fetch("classification", "safe"),
          "policy.applied_directives.classification", CLASSIFICATIONS.map(&:to_s)).to_sym
      end

      def read_closed_world(options)
        entries = mapping(options, "policy.closed_world", %w[enabled statement])
        enabled = choice(entries.fetch("enabled", false), "policy.closed_world.enabled", [true, false])
        statement = entries["statement"]
        if enabled || entries.key?("statement")
          statement = string(statement, "policy.closed_world.statement")
        end
        @closed_world_statement = statement if enabled
      end

      def deprecated_setting(value)
        return value if value == true || value == false

        options = mapping(value, "policy.allow_removal_of_deprecated", %w[min_days])
        days = options["min_days"]
        unless days.is_a?(Integer) && days >= 0
          raise LintCore::ConfigError, "policy.allow_removal_of_deprecated.min_days must be a non-negative integer."
        end

        days
      end

      def override(value)
        path = "policy.overrides"
        options = mapping(value, path, %w[change coordinate impacts classification])
        change = change_type(options["change"], "#{path}.change")
        coordinate = LintCore::CoordinatePattern.new(string(options["coordinate"], "#{path}.coordinate")) if options.key?("coordinate")
        impacts = choices(options["impacts"], "#{path}.impacts", IMPACTS) if options.key?("impacts")
        classification = choice(options["classification"], "#{path}.classification", CLASSIFICATIONS.map(&:to_s) + ["ignore"]).to_sym
        Rule.new(change: change, coordinate: coordinate, impacts: impacts, classification: classification, reason: nil, expires: nil)
      end

      def allowance(value)
        path = "policy.allow"
        options = mapping(value, path, %w[change coordinate reason expires])
        change = change_type(options["change"], "#{path}.change", allow_pattern: false)
        coordinate = LintCore::CoordinatePattern.new(string(options["coordinate"], "#{path}.coordinate"))
        reason = string(options["reason"], "#{path}.reason")
        expires = date(options["expires"], "#{path}.expires") if options.key?("expires")
        Rule.new(change: change, coordinate: coordinate, reason: reason, expires: expires, impacts: nil, classification: nil)
      end

      def change_type(value, path, allow_pattern: true)
        string(value, path)
        valid = if allow_pattern
          value.match?(/\A[A-Z_*]+\z/) && Catalog::ENTRIES.keys.any? { |id| File.fnmatch?(value, id) }
        else
          Catalog::ENTRIES.key?(value)
        end
        raise LintCore::ConfigError, "#{path} doesn't match a known change type." unless valid

        value
      end

      def mapping(value, path, keys)
        raise LintCore::ConfigError, "#{path} must be a mapping." unless value.is_a?(Hash)

        unknown = value.keys - keys
        unless unknown.empty?
          raise LintCore::ConfigError, "Unknown setting #{path}.#{unknown.first}."
        end

        value
      end

      def array(value, path)
        raise LintCore::ConfigError, "#{path} must be an array." unless value.is_a?(Array)

        value
      end

      def string(value, path)
        unless value.is_a?(String) && !value.strip.empty?
          raise LintCore::ConfigError, "#{path} must be a non-empty string."
        end

        value
      end

      def date(value, path)
        return value if value.is_a?(Date)

        Date.iso8601(string(value, path))
      rescue Date::Error
        raise LintCore::ConfigError, "#{path} must be an ISO 8601 date."
      end

      def choices(value, path, allowed)
        array(value, path).map { |item| choice(item, path, allowed.map(&:to_s)).to_sym }.uniq
      end

      def choice(value, path, allowed)
        unless allowed.include?(value)
          raise LintCore::ConfigError, "#{path} must be one of #{allowed.map(&:inspect).join(', ')}."
        end

        value
      end

      def diagnostic(type, severity, message)
        diagnostics << LintCore::Diagnostic.new(rule_id: "policy/#{type}", severity: severity, message: message)
      end

      def localized(english, japanese)
        @locale == "ja" ? japanese : english
      end
    end
  end
end
