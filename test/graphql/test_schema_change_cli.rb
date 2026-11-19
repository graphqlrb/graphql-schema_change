# frozen_string_literal: true

require_relative "../test_helper"
require "graphql/schema_change/cli"
require "stringio"
require "tmpdir"
require "open3"

class TestSchemaChangeCLI < Minitest::Test
  def test_lists_and_explains_changes
    status, output, errors = invoke("changes")
    assert_equal 0, status
    assert_includes output, "FIELD_TYPE_CHANGED"
    assert_empty errors

    status, output, = invoke("explain", "FIELD_TYPE_CHANGED")
    assert_equal 0, status
    assert_includes output, "The return type changed, which can affect selections and the shape of values."
  end

  def test_explain_validates_an_explicit_config_path
    Dir.mktmpdir("graphql-change-config") do |directory|
      path = File.join(directory, "missing.yml")
      status, output, errors = invoke("explain", "FIELD_TYPE_CHANGED", "--config", path)

      assert_equal 2, status
      assert_empty output
      assert_includes errors, path
    end
  end

  def test_checks_a_previous_git_revision_and_writes_multiple_formats
    Dir.mktmpdir("graphql-change-cli") do |directory|
      Dir.chdir(directory) do
        git("init", "-q")
        File.write("schema.graphql", "type Query { old: Int current: Int }\n")
        git("add", "schema.graphql")
        git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "Initial schema")
        File.write("schema.graphql", "type Query { current: Int }\n")

        status, output, errors = invoke("check", "--old", "git:HEAD:schema.graphql", "--new", "schema.graphql",
          "--format", "json", "--format", "markdown:reports/change.md", "--format", "github:reports/change.github")
        assert_empty errors
        assert_equal 1, status
        change = JSON.parse(output).fetch("changes").fetch(0)
        assert_equal "Query.old", change.fetch("coordinate")
        assert_equal "schema.graphql@HEAD", change.fetch("old_location").fetch("path")
        assert_includes File.read("reports/change.md"), "Query.old"
        assert_match(/::error file=schema\.graphql.*Original location: schema\.graphql@HEAD/, File.read("reports/change.github"))
      end
    end
  end

  def test_writes_and_respects_a_local_configuration
    Dir.mktmpdir("graphql-change-init") do |directory|
      Dir.chdir(directory) do
        assert_equal 0, invoke("init").first
        status, _, errors = invoke("init")
        assert_equal 2, status
        assert_match(/already exists/, errors)

        File.write(".graphql-schema-change.yml", "version: 1\nrules: {}\n")
        status, output, = invoke("check", "--format", "json")
        assert_equal 2, status
        assert_match(/rules/, JSON.parse(output).fetch("diagnostics").fetch(0).fetch("message"))
      end
    end
  end

  def test_github_output_escapes_multiline_stderr
    status, _, errors = invoke("check", "--format", "github", "unexpected argument\nsecond line")
    assert_equal 2, status
    assert_equal 1, errors.lines.length
    assert_includes errors, "second line"
  end

  def test_github_runner_environment_escapes_multiline_stderr
    original = ENV["GITHUB_ACTIONS"]
    ENV["GITHUB_ACTIONS"] = "true"
    status, _, errors = invoke("check", "unexpected argument\nsecond line")
    assert_equal 2, status
    assert_equal 1, errors.lines.length
  ensure
    ENV["GITHUB_ACTIONS"] = original
  end

  private

  def invoke(*arguments)
    output = StringIO.new
    errors = StringIO.new
    status = GraphQL::SchemaChange::CLI.run(arguments, stdout: output, stderr: errors)
    [status, output.string, errors.string]
  end

  def git(*arguments)
    output, status = Open3.capture2e("git", *arguments)
    assert status.success?, output
  end
end
