# frozen_string_literal: true

module GraphQL
  module SchemaChange
    class Diff
      EXECUTABLE_LOCATIONS = %w[
        QUERY MUTATION SUBSCRIPTION FIELD FRAGMENT_DEFINITION FRAGMENT_SPREAD INLINE_FRAGMENT VARIABLE_DEFINITION
      ].freeze
      ROOT_KINDS = %w[query mutation subscription].freeze
      SPECIAL_DIRECTIVES = %w[deprecated specifiedBy oneOf].freeze

      def initialize(old_index, new_index, settings, locale)
        @old, @new = old_index, new_index
        @settings, @locale = settings, locale
        @changes = []
      end

      def compare
        compare_schema
        pairs(@old.directives, @new.directives) { |before, after| compare_directive(before, after) }
        pairs(@old.types, @new.types) { |before, after| compare_type(before, after) }
        @changes
      end

      private

      def compare_schema
        ROOT_KINDS.each do |kind|
          before, after = @old.roots[kind], @new.roots[kind]
          next if before == after

          emit("ROOT_OPERATION_TYPE_#{verb(before, after)}",
            subject: {kind: :schema}, old_value: before, new_value: after,
            old_location: before && (@old.schema_location || @old.find(before)&.location),
            new_location: after && (@new.schema_location || @new.find(after)&.location), operation_kind: kind)
        end
        before, after = @old.schema_description, @new.schema_description
        if before != after
          emit("DESCRIPTION_CHANGED", subject: {kind: :schema}, old_value: before, new_value: after,
            old_location: @old.schema_location, new_location: @new.schema_location)
        end
        compare_applications(@old.schema_directives, @new.schema_directives, nil)
      end

      def compare_directive(before, after)
        return emit("DIRECTIVE_ADDED", after: after) unless before
        unless after
          options = before.executable? ? {} : type_system_directive
          if @settings.conservative? && !before.executable?
            options = {classification: :breaking, impacts: [:request]}
          end
          return emit("DIRECTIVE_REMOVED", before: before, **options)
        end

        compare_members(before, after)
        pairs_from_lists(before.locations, after.locations) do |location_before, location_after|
          options = location_before && !EXECUTABLE_LOCATIONS.include?(location_before.to_s) ? type_system_directive : {}
          emit("DIRECTIVE_LOCATION_#{verb(location_before, location_after)}",
            before: location_before && before, after: location_after && after,
            old_value: location_before, new_value: location_after, **options)
        end
        if before.repeatable? != after.repeatable?
          options = before.executable? || after.repeatable? ? {} : type_system_directive
          emit("DIRECTIVE_REPEATABLE_#{after.repeatable? ? 'ADDED' : 'REMOVED'}",
            before: before, after: after, old_value: before.repeatable?, new_value: after.repeatable?, **options)
        end
        pairs(before.arguments, after.arguments) do |left, right|
          executable = left ? before.executable? : after.executable?
          compare_input("DIRECTIVE_ARGUMENT", left, right, executable: executable)
        end
      end

      def compare_type(before, after)
        return emit("TYPE_ADDED", after: after, new_value: after.kind.to_s.upcase) unless before
        return emit("TYPE_REMOVED", before: before, old_value: before.kind.to_s.upcase) unless after
        if before.kind != after.kind
          return emit("TYPE_KIND_CHANGED", before: before, after: after,
            old_value: before.kind.to_s.upcase, new_value: after.kind.to_s.upcase)
        end

        compare_members(before, after)
        case before.kind
        when :object, :interface
          pairs_from_lists(before.interfaces, after.interfaces) do |left, right|
            emit("IMPLEMENTED_INTERFACE_#{verb(left, right)}",
              before: before, after: after, old_value: left, new_value: right)
          end
          pairs(before.fields, after.fields) { |left, right| compare_field(left, right) }
        when :input_object
          if before.one_of? != after.one_of?
            emit("INPUT_OBJECT_ONE_OF_#{after.one_of? ? 'ADDED' : 'REMOVED'}", before: before, after: after,
              old_value: before.one_of?, new_value: after.one_of?)
          end
          pairs(before.input_fields, after.input_fields) { |left, right| compare_input("INPUT_FIELD", left, right) }
        when :enum
          pairs(before.values, after.values) { |left, right| compare_enum(left, right, before, after) }
        when :union
          pairs_from_lists(before.possible_types, after.possible_types) do |left, right|
            emit("UNION_MEMBER_#{verb(left, right)}",
              before: before, after: after, old_value: left, new_value: right)
          end
        when :scalar
          return if before.specified_by_url == after.specified_by_url

          impacts = %i[input both].include?(before.position) ? %i[request response] : [:response]
          emit("SCALAR_SPECIFIED_BY_CHANGED", before: before, after: after,
            old_value: before.specified_by_url, new_value: after.specified_by_url, impacts: impacts)
        end
      end

      def compare_field(before, after)
        return emit("FIELD_ADDED", after: after, new_value: after.type.to_s) unless before
        return emit("FIELD_REMOVED", before: before, old_value: before.type.to_s) unless after

        compare_members(before, after)
        if before.type.to_s != after.type.to_s
          options = if TypeRefCompat.output_safe?(before.type, after.type)
            {classification: :safe, impacts: [], reason_key: "output_narrowed"}
          elsif TypeRefCompat.same_shape?(before.type, after.type)
            {impacts: [:response], reason_key: "output_weakened"}
          else
            {}
          end
          emit("FIELD_TYPE_CHANGED", before: before, after: after,
            old_value: before.type.to_s, new_value: after.type.to_s, **options)
        end
        pairs(before.arguments, after.arguments) { |left, right| compare_input("ARGUMENT", left, right) }
      end

      def compare_input(prefix, before, after, executable: true)
        type_system = executable ? {} : type_system_directive
        unless before
          options = if after.required? && executable
            {classification: :breaking, impacts: [:request], reason_key: "input_required"}
          elsif @settings.conservative? && prefix != "DIRECTIVE_ARGUMENT"
            {classification: :dangerous}
          else
            {}
          end
          return emit("#{prefix}_ADDED", after: after, new_value: after.type.to_s, **options)
        end
        return emit("#{prefix}_REMOVED", before: before, old_value: before.type.to_s, **type_system) unless after

        compare_members(before, after)
        if before.type.to_s != after.type.to_s
          options = if TypeRefCompat.input_safe?(before.type, after.type)
            {classification: :safe, impacts: [], reason_key: "input_widened"}
          else
            {}
          end
          emit("#{prefix}_TYPE_CHANGED", before: before, after: after,
            old_value: before.type.to_s, new_value: after.type.to_s, **options.merge(type_system))
        end
        old_default, new_default = before.default_value, after.default_value
        return if old_default.present? == new_default.present? && comparable(old_default) == comparable(new_default)

        options = {}
        if old_default.present? && after.required? && prefix != "DIRECTIVE_ARGUMENT"
          options = {classification: :breaking, impacts: [:request], reason_key: "input_default_removed"}
        end
        emit("#{prefix}_DEFAULT_VALUE_CHANGED", before: before, after: after,
          old_value: old_default.literal, new_value: new_default.literal, **options.merge(type_system))
      end

      def compare_enum(before, after, old_type, new_type)
        return compare_members(before, after) if before && after

        position = before ? old_type.position : new_type.position
        if after
          options = if %i[output both].include?(position)
            {classification: :dangerous, impacts: [:response]}
          else
            {classification: @settings.conservative? ? :dangerous : :safe, reason_key: "enum_input_added"}
          end
          emit("ENUM_VALUE_ADDED", after: after, **options)
        else
          options = case position
          when :output
            {classification: @settings.conservative? ? :breaking : :dangerous,
              impacts: [:response], reason_key: "enum_output_removed"}
          when :both then {impacts: %i[request response]}
          else {reason_key: "enum_input_removed"}
          end
          emit("ENUM_VALUE_REMOVED", before: before, **options)
        end
      end

      def compare_members(before, after)
        if before.description != after.description
          emit("DESCRIPTION_CHANGED", before: before, after: after,
            old_value: before.description, new_value: after.description)
        end
        if before.respond_to?(:deprecation) && (old_reason = before.deprecation&.reason) != (new_reason = after.deprecation&.reason)
          action = if before.deprecation.nil? then "ADDED"
          elsif after.deprecation.nil? then "REMOVED"
          else "REASON_CHANGED"
          end
          emit("DEPRECATION_#{action}", before: before, after: after, old_value: old_reason, new_value: new_reason)
        end
        compare_applications(before.directives, after.directives, before.coordinate) if before.respond_to?(:directives)
      end

      def compare_applications(before, after, target)
        return if @settings.tracked_directives.empty?

        old_by_name = before.group_by(&:name)
        new_by_name = after.group_by(&:name)
        @settings.tracked_directives.each do |name|
          next if SPECIAL_DIRECTIVES.include?(name)

          old_items = old_by_name.fetch(name, [])
          new_items = new_by_name.fetch(name, [])
          if old_items.size != new_items.size
            new_items = new_items.dup
            old_items = old_items.reject do |item|
              index = new_items.index { |candidate| argument_values(candidate) == argument_values(item) }
              new_items.delete_at(index) if index
            end
          end
          [old_items.size, new_items.size].max.times do |index|
            left, right = old_items[index], new_items[index]
            next if left && right && argument_values(left) == argument_values(right)

            action = left && right ? "ARGUMENT_CHANGED" : verb(left, right)
            classification = @settings.applied_classification
            emit("APPLIED_DIRECTIVE_#{action}", subject: {kind: :directive_application, target: target,
              directive: name, index: (right || left).index},
              old_value: left&.arguments&.transform_values(&:literal), new_value: right&.arguments&.transform_values(&:literal),
              default_classification: classification, impacts: classification == :safe ? [] : [:behavior],
              old_location: left&.location, new_location: right&.location,
              type_name: type_name_for(target))
          end
        end
      end

      def argument_values(application)
        application.arguments.transform_values { |value| comparable(value) }
      end

      def comparable(value)
        # Keep quoted strings distinct from enums while treating numerically equal representations alike.
        syntax = value.literal&.gsub(/"(?:\\.|[^"\\])*"|[_A-Za-z][_0-9A-Za-z]*|-?\d+(?:\.\d+)?(?:[Ee][+-]?\d+)?/) do |token|
          token.match?(/\A[-0-9]/) ? "#" : token
        end
        [value.value, syntax]
      end

      def emit(type, before: nil, after: nil, reason_key: type,
        old_location: before&.location, new_location: after&.location,
        type_name: type_name_for((before || after)&.coordinate), **attributes)
        position = (before || old_location ? @old : @new).find(type_name)&.position if type_name
        if type_name && @settings.downgrade_unreachable? &&
            !@old.find(type_name)&.reachable? && !@new.find(type_name)&.reachable?
          attributes = attributes.merge(classification: :safe, impacts: [])
          reason_key = "unreachable"
        end
        coordinate = (after || before)&.coordinate
        @changes << Change.new(type: type, coordinate: coordinate, reason: Catalog.reason(reason_key, @locale),
          position: position, old_location: old_location, new_location: new_location,
          deprecation: (before.deprecation if before.respond_to?(:deprecation)), **attributes)
      end

      def type_name_for(coordinate)
        coordinate&.split(".", 2)&.first unless coordinate&.start_with?("@")
      end

      def pairs(left, right)
        (left.keys | right.keys).sort.each do |key|
          before = visible(left[key])
          after = visible(right[key])
          yield before, after if before || after
        end
      end

      def visible(member)
        member unless member&.builtin? || member&.prelude?
      end

      def pairs_from_lists(left, right)
        (right - left).sort.each { |value| yield nil, value }
        (left - right).sort.each { |value| yield value, nil }
      end

      def verb(before, after)
        return "ADDED" unless before
        return "REMOVED" unless after

        "CHANGED"
      end

      def type_system_directive
        {classification: :safe, impacts: [], reason_key: "type_system_directive"}
      end
    end
  end
end
