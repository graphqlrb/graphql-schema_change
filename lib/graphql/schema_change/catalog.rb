# frozen_string_literal: true

require "yaml"

module GraphQL
  module SchemaChange
    module Catalog
      Entry = Data.define(:classification, :impacts, :matches, :conditional)

      ENTRIES = {
        "ROOT_OPERATION_TYPE_ADDED" => [:safe],
        "ROOT_OPERATION_TYPE_REMOVED" => [:breaking, %i[request], %i[operation_kind]],
        "ROOT_OPERATION_TYPE_CHANGED" => [:breaking, %i[request response], %i[operation_kind]],
        "TYPE_ADDED" => [:safe],
        "TYPE_REMOVED" => [:breaking, %i[request], %i[all_type_uses]],
        "TYPE_KIND_CHANGED" => [:breaking, %i[request response], %i[all_type_uses]],
        "SCALAR_SPECIFIED_BY_CHANGED" => [:dangerous, %i[response], %i[return_type variable_type], true],
        "FIELD_ADDED" => [:safe],
        "FIELD_REMOVED" => [:breaking, %i[request], %i[field]],
        "FIELD_TYPE_CHANGED" => [:breaking, %i[request response], %i[field], true],
        "IMPLEMENTED_INTERFACE_ADDED" => [:dangerous, %i[response], %i[interface_return_type]],
        "IMPLEMENTED_INTERFACE_REMOVED" => [:breaking, %i[request response], %i[interface_condition interface_return_type]],
        "ARGUMENT_ADDED" => [:safe, [], %i[omitted_argument], true],
        "ARGUMENT_REMOVED" => [:breaking, %i[request], %i[argument]],
        "ARGUMENT_TYPE_CHANGED" => [:breaking, %i[request], %i[argument omitted_required_argument], true],
        "ARGUMENT_DEFAULT_VALUE_CHANGED" => [:dangerous, %i[behavior], %i[omitted_argument], true],
        "INPUT_FIELD_ADDED" => [:safe, [], %i[variable_type input_literal_type], true],
        "INPUT_FIELD_REMOVED" => [:breaking, %i[request], %i[input_field variable_type]],
        "INPUT_FIELD_TYPE_CHANGED" => [:breaking, %i[request], %i[input_field variable_type input_literal_type], true],
        "INPUT_FIELD_DEFAULT_VALUE_CHANGED" => [:dangerous, %i[behavior], %i[variable_type input_literal_type], true],
        "INPUT_OBJECT_ONE_OF_ADDED" => [:breaking, %i[request], %i[variable_type input_literal_type]],
        "INPUT_OBJECT_ONE_OF_REMOVED" => [:safe],
        "ENUM_VALUE_ADDED" => [:safe, [], %i[return_type], true],
        "ENUM_VALUE_REMOVED" => [:breaking, %i[request], %i[enum_literal variable_type return_type], true],
        "UNION_MEMBER_ADDED" => [:dangerous, %i[response], %i[return_type]],
        "UNION_MEMBER_REMOVED" => [:breaking, %i[request response], %i[removed_member_condition return_type]],
        "DIRECTIVE_ADDED" => [:safe],
        "DIRECTIVE_REMOVED" => [:breaking, %i[request], %i[directive], true],
        "DIRECTIVE_LOCATION_ADDED" => [:safe],
        "DIRECTIVE_LOCATION_REMOVED" => [:breaking, %i[request], %i[directive], true],
        "DIRECTIVE_REPEATABLE_ADDED" => [:safe],
        "DIRECTIVE_REPEATABLE_REMOVED" => [:breaking, %i[request], %i[directive], true],
        "DIRECTIVE_ARGUMENT_ADDED" => [:safe, [], %i[directive], true],
        "DIRECTIVE_ARGUMENT_REMOVED" => [:breaking, %i[request], %i[directive], true],
        "DIRECTIVE_ARGUMENT_TYPE_CHANGED" => [:breaking, %i[request], %i[directive], true],
        "DIRECTIVE_ARGUMENT_DEFAULT_VALUE_CHANGED" => [:dangerous, %i[behavior], %i[directive], true],
        "APPLIED_DIRECTIVE_ADDED" => [:safe, [], %i[applied_directive], true],
        "APPLIED_DIRECTIVE_REMOVED" => [:safe, [], %i[applied_directive], true],
        "APPLIED_DIRECTIVE_ARGUMENT_CHANGED" => [:safe, [], %i[applied_directive], true],
        "DESCRIPTION_CHANGED" => [:safe],
        "DEPRECATION_ADDED" => [:safe, [], %i[deprecation]],
        "DEPRECATION_REMOVED" => [:safe],
        "DEPRECATION_REASON_CHANGED" => [:safe]
      }.transform_values do |classification, impacts = [], matches = [], conditional = false|
        Entry.new(classification, impacts.freeze, matches.freeze, conditional)
      end.freeze

      LOCALES = %w[en ja].to_h do |locale|
        path = File.expand_path("../../../locales/#{locale}.yml", __dir__)
        [locale, YAML.safe_load_file(path).freeze]
      end.freeze

      def self.reason(key, locale)
        LOCALES.fetch(locale, LOCALES.fetch("en")).fetch(key)
      end
    end
  end
end
