# frozen_string_literal: true

require_relative "lib/graphql/schema_change/version"

Gem::Specification.new do |spec|
  spec.name = "graphql-schema_change"
  spec.version = GraphQL::SchemaChange::VERSION
  spec.authors = ["Yudai Takada"]
  spec.summary = "Check GraphQL schemas for compatibility changes."
  spec.homepage = "https://github.com/ydah/graphql-lint"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir.glob(["lib/**/*.rb", "exe/*", "presets/*.yml", "examples/*.yml", "LICENSE.txt", "README.md", "docs/*.md"], base: __dir__).sort
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}).map { |file| File.basename(file) }
  spec.require_paths = ["lib"]
  spec.add_dependency "graphql-lint_core", "~> 0.1.0"
  spec.add_dependency "graphql", ">= 2.5", "< 3.0"
end
