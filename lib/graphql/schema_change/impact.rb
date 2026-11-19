# frozen_string_literal: true

module GraphQL
  module SchemaChange
    class Impact
      CAUSES = {
        "fields-on-correct-type" => %w[FIELD_REMOVED TYPE_REMOVED TYPE_KIND_CHANGED IMPLEMENTED_INTERFACE_REMOVED ROOT_OPERATION_TYPE_CHANGED FIELD_TYPE_CHANGED],
        "scalar-leafs" => %w[FIELD_TYPE_CHANGED TYPE_KIND_CHANGED],
        "known-argument-names" => %w[ARGUMENT_REMOVED INPUT_FIELD_REMOVED DIRECTIVE_ARGUMENT_REMOVED],
        "provided-required-arguments" => %w[ARGUMENT_ADDED ARGUMENT_DEFAULT_VALUE_CHANGED ARGUMENT_TYPE_CHANGED DIRECTIVE_ARGUMENT_ADDED DIRECTIVE_ARGUMENT_TYPE_CHANGED DIRECTIVE_ARGUMENT_DEFAULT_VALUE_CHANGED],
        "variables-in-allowed-position" => %w[ARGUMENT_TYPE_CHANGED INPUT_FIELD_TYPE_CHANGED DIRECTIVE_ARGUMENT_TYPE_CHANGED],
        "value-literals-of-correct-type" => %w[ARGUMENT_TYPE_CHANGED INPUT_FIELD_ADDED INPUT_FIELD_TYPE_CHANGED INPUT_FIELD_REMOVED INPUT_FIELD_DEFAULT_VALUE_CHANGED ENUM_VALUE_REMOVED INPUT_OBJECT_ONE_OF_ADDED DIRECTIVE_ARGUMENT_TYPE_CHANGED],
        "one-of-input-objects" => %w[INPUT_OBJECT_ONE_OF_ADDED],
        "known-type-names" => %w[TYPE_REMOVED TYPE_KIND_CHANGED],
        "fragments-on-composite-type" => %w[TYPE_KIND_CHANGED],
        "variables-are-input-types" => %w[TYPE_REMOVED TYPE_KIND_CHANGED],
        "possible-fragment-spread" => %w[TYPE_REMOVED TYPE_KIND_CHANGED UNION_MEMBER_REMOVED IMPLEMENTED_INTERFACE_REMOVED ROOT_OPERATION_TYPE_CHANGED FIELD_TYPE_CHANGED],
        "known-directives" => %w[DIRECTIVE_REMOVED DIRECTIVE_LOCATION_REMOVED],
        "unique-directives-per-location" => %w[DIRECTIVE_REPEATABLE_REMOVED],
        "known-operation-types" => %w[ROOT_OPERATION_TYPE_REMOVED ROOT_OPERATION_TYPE_CHANGED]
      }.freeze

      attr_reader :statistics, :broken, :diagnostics, :valid_before

      def initialize(set, old_schema, new_schema)
        @set = set
        @old, @new = old_schema, new_schema
        @diagnostics = set.diagnostics.map do |diagnostic|
          LintCore::Diagnostic.new(rule_id: diagnostic.rule_id, severity: :warning, message: diagnostic.message,
            location: diagnostic.location, related: diagnostic.related, operations: diagnostic.operations, data: diagnostic.data)
        end
        @broken = []
        @statistics = {count: set.operations.size, invalid_before: 0, invalid_before_operations: [],
          newly_valid: [], still_valid: 0, unverified: []}
      end

      def compare(changes)
        valid, invalidated = revalidate
        @valid_before = valid.size
        matcher = Matcher.new(@old.index, @new.index, @set, valid)
        candidates = Hash.new { |hash, operation| hash[operation] = [] }
        changes.each do |change|
          matches = matcher.matches(change)
          change.related_operations.concat(matches.map { |ref, confidence| operation_usage(ref, confidence) }.uniq)
          next unless invalidated.any?

          matches.each do |reference, confidence|
            if invalidated.key?(reference.operation)
              candidates[reference.operation] << [change, reference, confidence]
            end
          end
        end
        invalidated.each do |operation, (definition, errors)|
          attribute(operation, definition, errors, candidates[operation])
        end
      end

      def complete?
        @statistics.fetch(:unverified).empty? && @set.diagnostics.none? { |item| item.rule_id == "core/syntax-error" }
      end

      private

      def revalidate
        old_validator = LintCore::OperationValidator.new(@old)
        new_validator = LintCore::OperationValidator.new(@new)
        valid = Set.new
        invalidated = {}
        @set.units.each do |unit|
          next unless unit.operation

          name = unit.operation.display_name
          shared = @set.diagnostics_for(unit)
          before = old_validator.validate_unit(unit) + shared
          after = new_validator.validate_unit(unit) + shared
          warnings = (before + after).reject { |diagnostic| diagnostic.severity == :error }
          if warnings.any?
            @diagnostics.concat(warnings)
            @statistics[:unverified] << operation_entry(unit.operation)
          end

          if before.empty?
            valid.add(unit.operation)
            if after.empty?
              @statistics[:still_valid] += 1
            elsif warnings.empty?
              invalidated[name] = [unit.operation, after]
            end
          elsif before.any? { |diagnostic| diagnostic.severity == :error }
            @statistics[:invalid_before] += 1
            @statistics[:invalid_before_operations] << operation_entry(unit.operation).merge(errors: before.map(&:to_h))
            @statistics[:newly_valid] << operation_entry(unit.operation) if after.empty?
          end
        end
        [valid, invalidated]
      end

      def attribute(operation, definition, errors, candidates)
        attribution = errors.map do |error|
          ranked = candidates.filter_map do |change, reference, confidence|
            score = score_cause(error, change, reference, confidence)
            [score, change] if score
          end
          best = ranked.map(&:first).max
          ranked.select { |score, _| score == best }.map(&:last).uniq
        end
        causes = attribution.flatten.uniq
        entry = operation_entry(definition).merge(errors: errors.map(&:to_h),
          caused_by: causes.map { |change| {type: change.type, coordinate: change.coordinate, subject: change.subject}.compact },
          unattributed: attribution.any?(&:empty?))
        causes.each { |change| change.broken_operations << entry }
        @broken << entry.merge(causes: causes)
      end

      def score_cause(error, change, reference, confidence)
        rule = error.rule_id.delete_prefix("spec/")
        return unless CAUSES.fetch(rule, []).include?(change.type) && change.impacts.include?(:request)

        extension = error.data.fetch(:extensions, {})
        name = extension["fieldName"] || extension["argumentName"]
        relevant_names = extension["arguments"] || (name && [name])
        if relevant_names && !relevant_names.empty? && change.coordinate && !change.type.start_with?("TYPE_")
          coordinate_name = change.coordinate[/\((\w+):\)\z/, 1] || change.coordinate.split(".").last&.delete_prefix("@")
          return unless relevant_names.include?(coordinate_name) ||
            %w[FIELD_TYPE_CHANGED ENUM_VALUE_REMOVED INPUT_OBJECT_ONE_OF_ADDED].include?(change.type)
        end

        if change.type == "INPUT_OBJECT_ONE_OF_ADDED" && extension["inputObjectType"]
          return unless change.coordinate == extension["inputObjectType"].delete("[]!")
        end
        directive = extension["directiveName"] || (rule == "known-directives" && extension["name"])
        return if directive && change.coordinate != "@#{directive.delete_prefix('@')}"

        type = extension["typeName"]
        if change.type == "FIELD_REMOVED" && type && change.coordinate != "#{type}.#{name}"
          return
        end
        if change.type == "UNION_MEMBER_REMOVED" && type
          return unless type == change.old_value && extension["parentName"] == change.coordinate && confidence == "direct"
        end

        location = error.location
        return 5 if location && reference.location == location
        return 4 if same_path?(error, reference, change)
        return 3 if change.type.start_with?("ROOT_OPERATION_TYPE_")
        return 2 if confidence == "direct" && exact_schema_subject?(change, extension)

        1 if location && reference.location&.path == location.path && reference.location.line == location.line
      end

      def exact_schema_subject?(change, extension)
        case change.type
        when "FIELD_REMOVED"
          change.coordinate == "#{extension['typeName']}.#{extension['fieldName']}"
        when "DIRECTIVE_REMOVED", "DIRECTIVE_REPEATABLE_REMOVED"
          change.coordinate == "@#{extension['directiveName']}"
        when "TYPE_REMOVED", "TYPE_KIND_CHANGED"
          change.coordinate == extension["typeName"]
        when "UNION_MEMBER_REMOVED"
          change.old_value == extension["typeName"] && change.coordinate == extension["parentName"]
        end
      end

      def same_path?(error, reference, change)
        error_path = Array(error.data[:path]).drop(1)
        reference_path = Array(reference.path).drop(1)
        return false if error_path.empty? || reference_path.empty? || error.location&.path != reference.location&.path

        error_path == reference_path.take(error_path.size) ||
          (change.type == "FIELD_TYPE_CHANGED" && reference_path == error_path.take(reference_path.size))
      end

      def operation_entry(definition)
        {operation: definition.display_name, location: definition.location.to_h}
      end

      def operation_usage(reference, confidence)
        {operation: reference.operation, match: confidence, location: reference.location&.to_h,
          fragment_chain: reference.fragment_chain}
      end
    end

    class Matcher
      OperationUse = Data.define(:operation, :location, :fragment_chain, :path)

      def initialize(old_index, new_index, set, valid)
        @old, @new = old_index, new_index
        @operations = valid.group_by(&:kind)
        @direct = Hash.new { |hash, key| hash[key] = [] }
        @returns = Hash.new { |hash, key| hash[key] = [] }
        @fields = Hash.new { |hash, key| hash[key] = [] }
        @variable_types = Hash.new { |hash, key| hash[key] = [] }
        @nested_inputs = {}
        return if valid.empty?

        LintCore::UsageIndex.new(old_index, set).references.each do |ref|
          next unless valid.include?(ref.operation_definition)

          @direct[ref.coordinate] << ref
          if ref.kind == :field
            @returns[ref.return_type] << ref
            @fields[owner(ref.coordinate)] << ref
          elsif ref.via == :variable_type
            nested_inputs(ref.coordinate).each { |name| @variable_types[name] << ref }
          end
        end
      end

      def matches(change)
        coordinate = change.coordinate || change.subject&.[](:target)
        matches = Catalog::ENTRIES.fetch(change.type).matches.flat_map do |rule|
          references(rule, change, coordinate)
        end
        matches.uniq.sort_by do |reference, confidence|
          [reference.operation, reference.location&.path.to_s, reference.location&.line.to_i,
            reference.location&.column.to_i, confidence]
        end
      end

      private

      def references(rule, change, coordinate)
        case rule
        when :operation_kind
          @operations.fetch(change.operation_kind, []).map do |op|
            [OperationUse.new(operation: op.display_name, location: op.location, fragment_chain: [], path: []), "direct"]
          end
        when :field, :argument, :input_field, :enum_literal, :deprecation
          direct(@direct[coordinate])
        when :omitted_argument
          return [] if change.type == "ARGUMENT_ADDED" && !@new.find(coordinate)&.required?

          direct(omitted_argument(coordinate))
        when :omitted_required_argument
          return [] unless @new.find(coordinate)&.required? && !@old.find(coordinate)&.required?

          direct(omitted_argument(coordinate))
        when :directive
          return [] if change.type == "DIRECTIVE_ARGUMENT_ADDED" && (!@new.find(coordinate)&.required? || !@new.find(coordinate)&.owner&.executable?)

          direct(@direct[coordinate.split("(", 2).first])
        when :return_type
          returns(owner(coordinate))
        when :interface_return_type
          returns(change.old_value || change.new_value)
        when :removed_member_condition
          direct(type_conditions(change.old_value, change.coordinate))
        when :interface_condition
          direct(type_conditions(change.old_value, change.coordinate) + type_conditions(change.coordinate, change.old_value))
        when :variable_type
          return [] if change.type == "INPUT_FIELD_ADDED" && !@new.find(coordinate)&.required?

          @variable_types[owner(coordinate)].map { |ref| [ref, "type_level"] }
        when :input_literal_type
          if change.type == "INPUT_FIELD_ADDED"
            return [] unless @new.find(coordinate)&.required?
          elsif change.type == "INPUT_FIELD_TYPE_CHANGED"
            return [] unless @new.find(coordinate)&.required? && !@old.find(coordinate)&.required?
          end
          refs = @direct[owner(coordinate)].select { |ref| ref.via == :literal }
          if change.type.start_with?("INPUT_FIELD_")
            field = coordinate.split(".", 2).last
            refs = refs.reject { |ref| ref.node.arguments.any? { |arg| arg.name == field } }
          end
          direct(refs)
        when :all_type_uses
          direct(@direct[coordinate].reject { |ref| ref.via == :variable_type } + @fields[coordinate]) +
            returns(coordinate) + @variable_types[coordinate].map { |ref| [ref, "type_level"] }
        when :applied_directive
          direct(@direct[coordinate]) + (coordinate == owner(coordinate) ? returns(coordinate) : [])
        else
          []
        end
      end

      def type_conditions(condition, scope)
        @direct[condition].select { |ref| ref.via == :type_condition && ref.parent_type&.name == scope }
      end

      def omitted_argument(coordinate)
        field, argument = coordinate.split("(", 2)
        name = argument.delete_suffix(":)")
        @direct[field].reject { |ref| ref.node.arguments.any? { |arg| arg.name == name } }
      end

      def owner(coordinate)
        coordinate&.split(".", 2)&.first
      end

      def nested_inputs(type)
        @nested_inputs[type] ||= begin
          pending = [type]
          reachable = Set.new
          until pending.empty?
            name = pending.pop
            next unless reachable.add?(name)

            fields = @old.types[name]&.input_fields
            pending.concat(fields.values.map { |field| field.type.named }) if fields
          end
          reachable
        end
      end

      def direct(references)
        references.map { |ref| [ref, "direct"] }
      end

      def returns(type)
        @returns[type].map { |ref| [ref, "return_type"] }
      end
    end
  end
end
