# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "json"

class TestSchemaChange < Minitest::Test
  Checker = GraphQL::SchemaChange

  def test_reports_weaker_response_guarantees_without_invalidating_operations
    result = compare("type Query { label: [String!]! }", "type Query { label: [String]! }", "query Labels { label }")
    assert_equal 1, result.exit_status
    assert_empty result.broken_operations
    change = result.changes.fetch(0)
    assert_equal ["FIELD_TYPE_CHANGED", "Query.label", :breaking, [:response]], [
      change.type, change.coordinate, change.classification, change.impacts
    ]
    assert_equal "[String!]!", change.old_value
    assert_equal "[String]!", change.new_value
    assert_equal "Labels", change.related_operations.first.fetch(:operation)
  end

  def test_input_and_output_type_wrappers_have_opposite_variance
    assert Checker::TypeRefCompat.output_safe?("[[Int]]", "[[Int!]!]!")
    refute Checker::TypeRefCompat.output_safe?("[[Int!]!]!", "[[Int]]")
    assert Checker::TypeRefCompat.input_safe?("[[Int!]!]!", "[[Int]]")
    refute Checker::TypeRefCompat.input_safe?("[[Int]]", "[[Int!]!]!")
    refute Checker::TypeRefCompat.output_safe?("[Int]", "Int")
    refute Checker::TypeRefCompat.input_safe?("ID", "Int")
  end

  def test_distinguishes_enum_input_and_output_usage
    old = "enum In { A } enum Out { A B } type Query { value(arg: In): Out }"
    new = "enum In { A B } enum Out { A } type Query { value(arg: In): Out }"
    changes = compare(old, new).changes.to_h { |change| [change.type, change] }
    assert_equal [:input, :safe, []], change_profile(changes.fetch("ENUM_VALUE_ADDED"))
    assert_equal [:output, :dangerous, [:response]], change_profile(changes.fetch("ENUM_VALUE_REMOVED"))
    changes = compare(old, new, policy: {classification_profile: "conservative"}).changes
    assert_equal %i[dangerous breaking], changes.map(&:classification)
  end

  def test_unreachable_types_downgrade_without_an_operation_corpus
    old = "type Query { active: String } type Private { key: String }"
    new = "type Query { active: String }"
    assert_equal :safe, compare(old, new).changes.fetch(0).classification
    assert_equal :breaking, compare(old, new, policy: {unreachable: "keep"}).changes.fetch(0).classification
  end

  def test_normalizes_default_values_and_tracks_omitted_arguments
    old = "input Filter { a: Float b: Int } type Query { count(filter: Filter = {b: 2, a: 1}, first: Int = 10): Int }"
    new = "input Filter { a: Float b: Int } type Query { count(filter: Filter = {a: 1.0, b: 2}, first: Int = 20): Int }"
    result = compare(old, new, "query UsesDefault { count } query SuppliesValue { count(first: 5) }")
    change = result.changes.fetch(0)
    assert_equal 1, result.changes.length
    assert_equal "ARGUMENT_DEFAULT_VALUE_CHANGED", change.type
    assert_equal "Query.count(first:)", change.coordinate
    assert_equal [:behavior], change.impacts
    assert_equal ["UsesDefault"], change.related_operations.map { |operation| operation.fetch(:operation) }
  end

  def test_links_removed_field_in_a_shared_fragment
    old = "type Query { user: User } type User { id: ID old: String }"
    new = "type Query { user: User } type User { id: ID }"
    result = compare(old, new, {
      "query.graphql" => "query UsesFragment { user { ...Shared } }",
      "fragment.graphql" => "fragment Shared on User { old }",
      "invalid.graphql" => "query AlreadyInvalid { missing }"
    })
    assert_equal 1, result.exit_status
    assert_equal 1, result.broken_operations.length
    assert_equal 1, result.documents.fetch(:invalid_before)
    change = result.changes.fetch(0)
    assert_equal "FIELD_REMOVED", change.type
    assert_equal ["Shared"], change.related_operations.fetch(0).fetch(:fragment_chain)
    assert_equal "UsesFragment", change.broken_operations.fetch(0).fetch(:operation)
  end

  def test_links_required_argument_addition
    result = compare("type Query { user: ID }", "type Query { user(id: ID!): ID }", "query User { user }")
    change = result.changes.fetch(0)
    assert_equal :breaking, change.classification
    assert_equal "Query.user(id:)", change.coordinate
    assert_equal "User", change.broken_operations.fetch(0).fetch(:operation)
  end

  def test_links_input_types_reachable_from_a_variable
    old = "input Outer { inner: Inner } input Inner { key: String } type Query { value(input: Outer): Int }"
    new = "input Outer { inner: Inner } input Inner { key: String! } type Query { value(input: Outer): Int }"
    result = compare(old, new, 'query Q($outer: Outer) { value(input: $outer) }')
    assert_empty result.broken_operations
    assert_equal "type_level", result.changes.fetch(0).related_operations.fetch(0).fetch(:match)
  end

  def test_detects_one_of_and_reports_preexisting_document_syntax_as_warning
    old = "input Choice { a: Int b: Int } type Query { value(choice: Choice): Int }"
    new = "input Choice @oneOf { a: Int b: Int } type Query { value(choice: Choice): Int }"
    result = compare(old, new, {"broken.graphql" => "query Q { value(choice: {a: 1, b: 2}) }", "syntax.graphql" => "{"})
    assert_equal "INPUT_OBJECT_ONE_OF_ADDED", result.changes.fetch(0).type
    assert_equal "Q", result.changes.fetch(0).broken_operations.fetch(0).fetch(:operation)
    assert_equal :warning, result.diagnostics.find { |diagnostic| diagnostic.rule_id == "core/syntax-error" }.severity
  end

  def test_undefined_one_of_variable_is_reported_as_preexisting_invalidity
    old = "input Choice { a: Int } type Query { use(choice: Choice): Int }"
    new = "input Choice @oneOf { a: Int } type Query { use(choice: Choice): Int }"
    result = compare(old, new, "query Q { use(choice: {a: $unknown}) }")
    assert_equal 1, result.exit_status
    assert_equal 1, result.documents.fetch(:invalid_before)
    assert_empty result.broken_operations
  end

  def test_unmatched_operation_corpus_never_downgrades_by_default
    result = compare("type Query { a: Int b: Int }", "type Query { b: Int }", "query Q { b }")
    assert result.changes.fetch(0).breaking?
    assert_empty result.changes.fetch(0).related_operations
    assert_match(/no known operation/i, result.render("text"))
  end

  def test_closed_world_requires_a_statement_and_a_usable_operation_corpus
    old = "type Query { a: Int b: Int }"
    new = "type Query { b: Int }"
    assert_equal 2, compare(old, new, policy: {closed_world: {enabled: true}}).exit_status
    policy = {closed_world: {enabled: true, statement: "All queries are persisted."}}
    result = compare(old, new, "query Q { b }", policy: policy)
    assert_equal :dangerous, result.changes.fetch(0).classification
    assert_equal "All queries are persisted.", JSON.parse(result.to_json).fetch("closed_world")
    result = compare(old, new, policy: policy)
    assert result.changes.fetch(0).breaking?
    assert_includes result.diagnostics.map(&:rule_id), "policy/empty-closed-world"
  end

  def test_overrides_precede_allow_and_expired_allow_is_an_error
    old = "type Query { drop: Int keep: Int }"
    new = "type Query { keep: Int }"
    allowance = {change: "FIELD_REMOVED", coordinate: "Query.*", reason: "The client was retired", expires: "2026-06-01"}
    config = {today: "2026-06-01", policy: {allow: [allowance]}}
    result = compare(old, new, "query UsesDrop { drop }", **config)
    assert_equal 0, result.exit_status
    assert_equal :allowed, result.changes.fetch(0).policy.fetch(:result)
    assert_equal 1, compare(old, new, "query UsesDrop { drop }",
      today: "2026-06-01", policy: {allow: [allowance], fail_on_broken_operations: "always"}).exit_status
    result = compare(old, new, today: "2026-06-02", policy: {allow: [allowance]})
    assert_equal 1, result.exit_status
    assert_includes result.diagnostics.map(&:rule_id), "policy/expired-allow"

    config[:policy][:overrides] = [{change: "FIELD_*", classification: "ignore"}]
    result = compare(old, new, **config)
    assert_equal :ignored, result.changes.fetch(0).policy.fetch(:result)
    assert_empty JSON.parse(result.to_json).fetch("changes")
  end

  def test_allows_deprecated_removals_only_old_enough
    old = 'type Query { remove: Int @deprecated(reason: "2026-06-01") keep: Int }'
    new = "type Query { keep: Int }"
    policy = {allow_removal_of_deprecated: {min_days: 30}}
    assert_equal 1, compare(old, new, today: "2026-06-30", policy: policy).exit_status
    assert_equal 0, compare(old, new, today: "2026-07-01", policy: policy).exit_status
  end

  def test_ignores_untracked_directives_and_detects_tracked_applications
    old = 'directive @visibility(role: String) on FIELD_DEFINITION type Query { a: Int @visibility(role: "public") }'
    new = 'directive @visibility(role: String) on FIELD_DEFINITION type Query { a: Int @visibility(role: "private") }'
    assert_empty compare(old, new).changes
    change = compare(old, new, policy: {applied_directives: {track: ["visibility"], classification: "dangerous"}}).changes.fetch(0)
    assert_equal "APPLIED_DIRECTIVE_ARGUMENT_CHANGED", change.type
    assert_nil change.coordinate
    assert_equal "Query.a", change.subject.fetch(:target)
    assert_equal [:behavior], change.impacts
  end

  def test_repeating_directives_preserve_the_order_of_applications
    old = 'directive @order(key: String) repeatable on FIELD_DEFINITION type Query { a: Int @order(key: "first") @order(key: "second") }'
    new = 'directive @order(key: String) repeatable on FIELD_DEFINITION type Query { a: Int @order(key: "second") @order(key: "first") }'
    policy = {applied_directives: {track: ["order"], classification: "dangerous"}}
    changes = compare(old, new, policy: policy).changes
    assert_equal ["APPLIED_DIRECTIVE_ARGUMENT_CHANGED"] * 2, changes.map(&:type)
    assert_equal [0, 1], changes.map { |change| change.subject.fetch(:index) }
    assert_equal changes.map(&:new_value).reverse, changes.map(&:old_value)
  end

  def test_closed_world_does_not_downgrade_when_a_known_document_could_not_be_parsed
    old = "type Query { a: Int b: Int }"
    new = "type Query { b: Int }"
    policy = {closed_world: {enabled: true, statement: "All queries are persisted."}}
    result = compare(old, new, {"usable.graphql" => "query B { b }", "unusable.graphql" => "{"}, policy: policy)
    assert result.changes.fetch(0).breaking?
    assert_includes result.diagnostics.map(&:rule_id), "policy/incomplete-closed-world"
  end

  def test_policy_hooks_run_after_overrides
    Checker.configure do |config|
      config.policy_hook do |change, context|
        if change.coordinate == "Hooks.before" && change.classification == :dangerous
          change.reclassify(:breaking, reason: "A binding client contract applies as of #{context.fetch(:today)}.")
        end
      end
    end
    old = "type Query { hooks: Hooks } type Hooks { before: Int after: Int }"
    new = "type Query { hooks: Hooks } type Hooks { after: Int }"
    policy = {overrides: [{change: "FIELD_REMOVED", classification: "dangerous"}]}
    result = compare(old, new, policy: policy, today: "2026-01-01")
    assert_equal 1, result.exit_status
    change = result.changes.fetch(0)
    assert_equal "policy_hook", change.policy.fetch(:matched)
    assert_includes change.reason, "2026-01-01"
  end

  def test_keeps_safe_changes_in_json
    result = compare("type Query { a: Int }", "type Query { a: Int b: Int }", policy: {report_safe: false})
    assert_equal 1, JSON.parse(result.to_json).fetch("changes").length
    refute_includes result.render("text"), "Query.b"
  end

  def test_attributes_removed_union_member_only_in_its_original_scope
    old = "type A { a: Int } type B { b: Int } union U = A | B union V = A | B type Query { u: U v: V }"
    new = "type A { a: Int } type B { b: Int } union U = A union V = A | B type Query { u: U v: V }"
    result = compare(old, new, "query Affected { u { ...OnlyB } } query Unaffected { v { ...OnlyB } } fragment OnlyB on B { b }")
    change = result.changes.fetch(0)
    assert_equal ["Affected"], change.related_operations.map { |operation| operation[:operation] }.uniq
    assert_equal ["Affected"], change.broken_operations.map { |operation| operation[:operation] }
  end

  def test_attributes_required_input_fields_to_the_correct_input_type
    old = "input A { x: Int y: Int } input B { x: Int y: Int } type Query { a(input: A): Int b(input: B): Int }"
    new = "input A { x: Int! y: Int } input B { x: Int! y: Int } type Query { a(input: A): Int b(input: B): Int }"
    result = compare(old, new, "query Q { a(input: {y: 1}) b(input: {x: 1}) }")
    assert_equal ["A.x"], result.broken_operations.fetch(0).fetch(:caused_by).map { |change| change.fetch(:coordinate) }
  end

  def test_schema_descriptions_use_the_schema_subject
    old = '"Before." schema { query: Query } type Query { a: Int }'
    new = '"After." schema { query: Query } type Query { a: Int }'
    result = compare(old, new)
    change = result.changes.fetch(0)
    assert_equal "DESCRIPTION_CHANGED", change.type
    assert_equal({kind: :schema}, change.subject)
    assert_equal "Before.", change.old_value
    assert_equal "After.", change.new_value
    assert_nil change.coordinate
  end

  def test_markdown_bounds_large_output_and_escapes_configured_prose
    old = "type Query { a: Int }"
    new = %Q(type Query { a: Int """#{'x' * 70_000}""" b: Int })
    policy = {closed_world: {enabled: true, statement: "<img src=example> " + "y" * 70_000}}
    markdown = compare(old, new, "query Valid { a }", policy: policy).render("markdown")
    assert_operator markdown.bytesize, :<=, Checker::Result::MARKDOWN_LIMIT
    refute_includes markdown, "<img"
    assert_includes markdown, "&lt;img"
  end

  def test_unknown_policy_configuration_and_invalid_schemas_exit_two
    assert_equal 2, compare("type Query { a: Int }", "type Query { a: Int }", policy: {typo: true}).exit_status
    result = compare("type Query { a: Unavailable }", "type Query { a: Int }")
    assert_equal 2, result.exit_status
    assert_empty result.changes
    assert result.fatal?
  end

  def test_catalog_includes_a_reason_for_each_change
    Checker::Catalog::ENTRIES.each_key do |id|
      assert Checker::Catalog.reason(id).length > 15, id
    end
  end

  def test_equal_schemas_produce_no_changes
    source = "type Query { email: String }"
    assert_empty compare(source, source).changes
  end

  private

  def change_profile(change)
    [change.position, change.classification, change.impacts]
  end

  def compare(old, new, documents = nil, **config)
    Dir.mktmpdir("graphql-schema-change") do |directory|
      old_path = File.join(directory, "old.graphql")
      new_path = File.join(directory, "new.graphql")
      File.write(old_path, old)
      File.write(new_path, new)
      documents = {"operation.graphql" => documents} if documents.is_a?(String)
      paths = documents&.map do |name, source|
        File.join(directory, name).tap { |path| File.write(path, source) }
      end
      Checker.check(old: old_path, new: new_path, documents: paths, config: {version: 1, **config})
    end
  end
end
