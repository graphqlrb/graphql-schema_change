# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class TestChangeCatalog < Minitest::Test
  Checker = GraphQL::SchemaChange
  QUERY = "type Query { value: Int }"

  def test_detects_every_change_type_in_the_catalog
    covered = []
    each_case do |before, after, expected|
      forward = compare(before, after)
      reverse = compare(after, before)
      assert_equal expected.sort, forward.changes.map(&:type).sort, forward.diagnostics.map(&:message).join("\n")
      assert_equal expected.map { |id| reverse_type(id) }.sort, reverse.changes.map(&:type).sort,
        reverse.diagnostics.map(&:message).join("\n")
      refute_equal 3, forward.exit_status
      refute_equal 3, reverse.exit_status
      covered.concat(forward.changes.map(&:type), reverse.changes.map(&:type))
    end
    assert_equal Checker::Catalog::ENTRIES.keys.sort, covered.uniq.sort
  end

  def test_nullable_required_and_optional_input_classifications
    old = "input Input { a: Int b: Int! = 1 } type Query { value(criteria: Input, count: Int! = 1): Int }"
    new = "input Input { a: Int! b: Int } type Query { value(criteria: Input, count: Int!): Int! }"
    changes = compare(old, new).changes.to_h { |change| [[change.type, change.coordinate], change] }
    assert_equal :breaking, changes.fetch(["INPUT_FIELD_TYPE_CHANGED", "Input.a"]).classification
    assert_equal :safe, changes.fetch(["INPUT_FIELD_TYPE_CHANGED", "Input.b"]).classification
    assert_equal :dangerous, changes.fetch(["INPUT_FIELD_DEFAULT_VALUE_CHANGED", "Input.b"]).classification
    assert_equal :breaking, changes.fetch(["ARGUMENT_DEFAULT_VALUE_CHANGED", "Query.value(count:)"]).classification
    assert_equal :safe, changes.fetch(["FIELD_TYPE_CHANGED", "Query.value"]).classification
  end

  def test_directive_position_restrictions_and_conservative_profile
    prefix = "directive @meta on FIELD | FIELD_DEFINITION "
    prefix_without_sdl = "directive @meta on FIELD "
    change = compare(prefix + QUERY, prefix_without_sdl + QUERY).changes.fetch(0)
    assert_equal "DIRECTIVE_LOCATION_REMOVED", change.type
    assert_equal :safe, change.classification
    change = compare("directive @meta on FIELD_DEFINITION " + QUERY, QUERY,
      policy: {classification_profile: "conservative"}).changes.fetch(0)
    assert_equal :breaking, change.classification
    assert_equal [:request], change.impacts
  end

  def test_conservative_classifier_matches_optional_input_addition_categories
    old = "input Input { existing: Int } type Query { q(input: Input): Int }"
    new = "input Input { existing: Int offset: Int } type Query { q(input: Input, limit: Int = 10): Int }"
    expected = %w[ARGUMENT_ADDED INPUT_FIELD_ADDED]
    assert_equal expected, compare(old, new).changes.map(&:type).sort
    assert_equal [:safe, :safe], compare(old, new).changes.map(&:classification)
    changes = compare(old, new, policy: {classification_profile: "conservative"}).changes
    assert_equal [:dangerous, :dangerous], changes.map(&:classification)
  end

  def test_normalizes_numbers_without_treating_string_literals_as_enums
    old = 'scalar Any input Filter { code: Any number: Float } type Query { q(f: Filter = {code: A, number: 2}): Int }'
    new = 'scalar Any input Filter { number: Float code: Any } type Query { q(f: Filter = {number: 2.0, code: "A"}): Int }'
    changes = compare(old, new).changes
    assert_equal ["ARGUMENT_DEFAULT_VALUE_CHANGED"], changes.map(&:type)
  end

  private

  def each_case
    yield QUERY, QUERY + " type Mutation { update: Int }", %w[ROOT_OPERATION_TYPE_ADDED TYPE_ADDED]
    yield "schema { query: Old } type Old { value: Int }", "schema { query: New } type New { value: Int }",
      %w[ROOT_OPERATION_TYPE_CHANGED TYPE_ADDED TYPE_REMOVED]
    yield "scalar A type Query { a: A }", "enum A { B } type Query { a: A }", %w[TYPE_KIND_CHANGED]
    yield 'scalar A @specifiedBy(url: "https://example.com/a") type Query { a: A }',
      'scalar A @specifiedBy(url: "https://example.com/b") type Query { a: A }', %w[SCALAR_SPECIFIED_BY_CHANGED]
    yield QUERY, "type Query { value: String existing(arg: Int): Int }", %w[FIELD_TYPE_CHANGED FIELD_ADDED]
    yield "interface Node { id: ID } type A { id: ID } type Query { a: A }",
      "interface Node { id: ID } type A implements Node { id: ID } type Query { a: A }",
      %w[IMPLEMENTED_INTERFACE_ADDED]
    yield QUERY, "type Query { value(a: Int): Int }", %w[ARGUMENT_ADDED]
    yield "type Query { value(a: Int = 1): Int }", "type Query { value(a: Float = 2): Int }",
      %w[ARGUMENT_TYPE_CHANGED ARGUMENT_DEFAULT_VALUE_CHANGED]
    yield "input I { a: Int } type Query { q(i: I): Int }",
      "input I { a: String b: Int } type Query { q(i: I): Int }", %w[INPUT_FIELD_TYPE_CHANGED INPUT_FIELD_ADDED]
    yield "input I { a: Int = 1 } type Query { q(i: I): Int }",
      "input I { a: Int = 2 } type Query { q(i: I): Int }", %w[INPUT_FIELD_DEFAULT_VALUE_CHANGED]
    yield "input I { a: Int } type Query { q(i: I): Int }",
      "input I @oneOf { a: Int } type Query { q(i: I): Int }", %w[INPUT_OBJECT_ONE_OF_ADDED]
    yield "enum E { A } type Query { q: E }", "enum E { A B } type Query { q: E }", %w[ENUM_VALUE_ADDED]
    yield "type A { a: Int } type B { b: Int } union U = A type Query { u: U }",
      "type A { a: Int } type B { b: Int } union U = A | B type Query { u: U }", %w[UNION_MEMBER_ADDED]
    yield QUERY, "directive @marker on FIELD " + QUERY, %w[DIRECTIVE_ADDED]
    yield "directive @marker on FIELD " + QUERY,
      "directive @marker repeatable on FIELD | QUERY " + QUERY, %w[DIRECTIVE_REPEATABLE_ADDED DIRECTIVE_LOCATION_ADDED]
    yield "directive @marker on FIELD " + QUERY, "directive @marker(a: Int) on FIELD " + QUERY, %w[DIRECTIVE_ARGUMENT_ADDED]
    yield "directive @marker(a: Int = 1) on FIELD " + QUERY,
      "directive @marker(a: Float = 2) on FIELD " + QUERY, %w[DIRECTIVE_ARGUMENT_TYPE_CHANGED DIRECTIVE_ARGUMENT_DEFAULT_VALUE_CHANGED]
    yield "directive @marker on FIELD_DEFINITION " + QUERY,
      "directive @marker on FIELD_DEFINITION type Query { value: Int @marker }", %w[APPLIED_DIRECTIVE_ADDED]
    yield "directive @marker(a: Int) on FIELD_DEFINITION type Query { value: Int @marker(a: 1) }",
      "directive @marker(a: Int) on FIELD_DEFINITION type Query { value: Int @marker(a: 2) }", %w[APPLIED_DIRECTIVE_ARGUMENT_CHANGED]
    yield QUERY, 'type Query { "The value." value: Int @deprecated(reason: "Use another field.") }',
      %w[DESCRIPTION_CHANGED DEPRECATION_ADDED]
    yield 'type Query { value: Int @deprecated(reason: "Old.") }',
      'type Query { value: Int @deprecated(reason: "New.") }', %w[DEPRECATION_REASON_CHANGED]
  end

  def reverse_type(type)
    return type.sub(/_ADDED\z/, "_REMOVED") if type.end_with?("_ADDED")
    return type.sub(/_REMOVED\z/, "_ADDED") if type.end_with?("_REMOVED")

    type
  end

  def compare(before, after, policy: {})
    Dir.mktmpdir("graphql-change-catalog") do |directory|
      old = File.join(directory, "old.graphql")
      new = File.join(directory, "new.graphql")
      File.write(old, before)
      File.write(new, after)
      policy = {applied_directives: {track: ["marker"]}}.merge(policy)
      Checker.check(old: old, new: new, config: {version: 1, policy: policy})
    end
  end
end
