# frozen_string_literal: true

require "fileutils"
require "graphql/schema_change"

path = File.expand_path("../docs/changes.md", __dir__)
catalog = GraphQL::SchemaChange::Catalog
lines = ["# Schema change catalog", "",
  "Use these IDs in `policy.overrides` and `policy.allow`.",
  "Conditional changes can receive a different classification or impact based on how a changed schema element is used.", "",
  "| ID | Default classification | Impact | Conditional | Reason |",
  "| --- | --- | --- | --- | --- |"]

catalog::ENTRIES.sort.each do |id, change|
  impacts = change.impacts.map { |value| "`#{value}`" }.join(", ")
  reason = catalog.reason(id).gsub("|") { "\\|" }
  lines << "| `#{id}` | `#{change.classification}` | #{impacts} | #{change.conditional ? "Yes" : "No"} | #{reason} |"
end

content = lines.join("\n") + "\n"
if ARGV.include?("--check")
  abort("docs/changes.md is outdated. Run bundle exec rake docs:generate.") unless
    File.file?(path) && File.read(path, encoding: "UTF-8").gsub("\r\n", "\n") == content
else
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content, encoding: "UTF-8")
end
