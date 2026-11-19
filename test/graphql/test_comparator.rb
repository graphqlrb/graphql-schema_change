# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestSchemaComparator < Minitest::Test
  Checker = GraphQL::SchemaChange

  def setup
    require "graphql/schema_comparator"
  rescue LoadError
    skip "The optional graphql-schema_comparator reference implementation is unavailable."
  end

  def test_matches_supported_change_detection_for_generated_schema_pairs
    random = Random.new(42)
    100.times do |index|
      field = "item#{index}"
      option = "option#{index}"
      old_schema = <<~GRAPHQL
        enum Role { ADMIN SUPPORT }
        input Filter { count: Int = 10 limit: Int }
        type Result { score: Int! oldRank: Int }
        type Query {
          #{field}(role: Role, filter: Filter, #{option}: Int = 1): Result
          existing: Int
        }
      GRAPHQL
      edits = [
        ["score: Int!", "score: Int"],
        ["oldRank: Int", "rank: Int"],
        ["ADMIN SUPPORT", "ADMIN VIEWER"],
        ["limit: Int", "offset: Int"],
        ["count: Int = 10", "count: Int = 20"],
        ["#{option}: Int = 1", "#{option}: Int = 2, active: Boolean"],
        ["role: Role, ", ""],
        ["existing: Int", '"A description." existing: Int']
      ]
      new_schema = edits.sample(random.rand(1..3), random: random).reduce(old_schema) do |schema, (old, new)|
        schema.sub(old, new)
      end
      expected = GraphQL::SchemaComparator.compare(old_schema, new_schema).changes.map { |item| comparator_key(item) }
      changes = compare(old_schema, new_schema)
      assert_equal expected.sort, changes.map { |change| [change.type, change.coordinate] }.sort, "pair #{index}"
    end
  end

  def test_detects_changes_outside_the_reference_implementation
    cases = {
      "INPUT_OBJECT_ONE_OF_ADDED" => [
        "input I { a: Int } type Query { q(i: I): Int }",
        "input I @oneOf { a: Int } type Query { q(i: I): Int }"
      ],
      "DIRECTIVE_REPEATABLE_REMOVED" => [
        "directive @marker repeatable on FIELD type Query { q: Int }",
        "directive @marker on FIELD type Query { q: Int }"
      ],
      "APPLIED_DIRECTIVE_REMOVED" => [
        "directive @marker on FIELD_DEFINITION type Query { q: Int @marker }",
        "directive @marker on FIELD_DEFINITION type Query { q: Int }"
      ],
      "SCALAR_SPECIFIED_BY_CHANGED" => [
        'scalar Custom @specifiedBy(url: "https://example.com/one") type Query { q: Custom }',
        'scalar Custom @specifiedBy(url: "https://example.com/two") type Query { q: Custom }'
      ]
    }
    cases.each do |type, (old_schema, new_schema)|
      assert_empty GraphQL::SchemaComparator.compare(old_schema, new_schema).changes
      assert_equal [type], compare(old_schema, new_schema).map(&:type)
    end
  end

  private

  def compare(old_schema, new_schema)
    settings = Checker::Policy.new({"applied_directives" => {"track" => ["marker"]}}, today: nil)
    loader = GraphQL::LintCore::SchemaLoader
    indexes = [old_schema, new_schema].map do |schema|
      loaded = loader.load("-", stdin: StringIO.new(schema))
      refute loaded.fatal?, loaded.diagnostics.map(&:message).join("\n")
      loaded.index
    end
    Checker::Diff.new(*indexes, settings).compare
  end

  def comparator_key(change)
    type = change.class.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').upcase
    coordinate = change.path
    if type.start_with?("FIELD_ARGUMENT_")
      type = type.delete_prefix("FIELD_")
      field, _, argument = coordinate.rpartition(".")
      coordinate = "#{field}(#{argument}:)"
    end
    type = type.sub("_DEFAULT_CHANGED", "_DEFAULT_VALUE_CHANGED")
    type = "DESCRIPTION_CHANGED" if type.end_with?("_DESCRIPTION_CHANGED")
    [type, coordinate]
  end
end
