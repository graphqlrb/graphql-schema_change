# frozen_string_literal: true

module GraphQL
  module SchemaChange
    # @api public
    class Change
      attr_reader :type, :coordinate, :subject, :old_value, :new_value, :default_classification,
        :classification, :impacts, :reason, :position, :old_location, :new_location,
        :related_operations, :broken_operations, :operation_kind, :deprecation
      attr_accessor :policy

      def initialize(type:, reason:, coordinate: nil, subject: nil, old_value: nil, new_value: nil,
        old_location: nil, new_location: nil, classification: nil, impacts: nil, position: nil,
        default_classification: nil, operation_kind: nil, deprecation: nil)
        entry = Catalog::ENTRIES.fetch(type)
        @type = type
        @coordinate = coordinate
        @subject = subject
        @old_value = old_value
        @new_value = new_value
        @default_classification = default_classification || entry.classification
        @classification = classification || @default_classification
        @impacts = (impacts || entry.impacts).dup
        @reason = reason
        @position = position
        @old_location = old_location
        @new_location = new_location
        @operation_kind = operation_kind
        @deprecation = deprecation
        @related_operations = []
        @broken_operations = []
        @policy = {result: :pass}
      end

      def breaking?
        classification == :breaking
      end

      # @api public
      def reclassify(classification, reason:)
        unless Policy::CLASSIFICATIONS.include?(classification)
          raise ArgumentError, "Invalid change classification #{classification.inspect}."
        end

        @classification = classification
        @reason = reason
        @impacts.clear if classification == :safe
        self
      end

      def to_h
        {
          type: type, coordinate: coordinate, subject: subject, old_value: old_value, new_value: new_value,
          default_classification: default_classification, classification: classification, impacts: impacts,
          reason: reason, position: position, old_location: old_location&.to_h, new_location: new_location&.to_h,
          related_operations: related_operations, broken_operations: broken_operations, policy: policy, operation_kind: operation_kind
        }.compact.merge(old_value: old_value, new_value: new_value)
      end
    end
  end
end
