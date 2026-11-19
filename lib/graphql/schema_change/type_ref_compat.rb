# frozen_string_literal: true

require "set"

module GraphQL
  module SchemaChange
    module TypeRefCompat
      module_function

      def output_safe?(old_type, new_type)
        compatible?(old_type, new_type)
      end

      def input_safe?(old_type, new_type)
        compatible?(new_type, old_type)
      end

      def same_shape?(old_type, new_type)
        old_type.to_s.delete("!") == new_type.to_s.delete("!")
      end

      def compatible?(weaker, stronger)
        return false unless same_shape?(weaker, stronger)

        required_levels(weaker).subset?(required_levels(stronger))
      end

      def required_levels(type)
        depth = type.to_s.count("[")
        type.to_s.each_char.each_with_object(Set.new) do |character, levels|
          case character
          when "!" then levels.add(depth)
          when "]" then depth -= 1
          end
        end
      end
      private_class_method :compatible?, :required_levels
    end
  end
end
