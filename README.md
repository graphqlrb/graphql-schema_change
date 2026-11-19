# GraphQL Schema Change

Compare two GraphQL schemas for breaking, dangerous and safe changes. Optionally
check existing operations against both schemas to find newly invalid operations
and changes that affect the requests or responses they use.

## Installation

This gem is unreleased. Place a `graphql-lint_core` checkout beside this
repository or set `GRAPHQL_LINT_CORE_PATH` to its location, then run
`bundle install`. Bundler uses RubyGems when a local Core checkout is unavailable.

## Quick start

```sh
bundle exec ruby exe/graphql-schema-change check --old before.graphql --new after.graphql
bundle exec ruby exe/graphql-schema-change check --old git:HEAD:schema.graphql --new schema.graphql \
  --documents 'operations/**/*.graphql' --format json
bundle exec ruby exe/graphql-schema-change explain FIELD_TYPE_CHANGED
```

To use the Ruby API:

```ruby
require "graphql/schema_change"

result = GraphQL::SchemaChange.check(old: "before.graphql", new: "after.graphql")
result.changes.select(&:breaking?).each { |change| puts change.coordinate }
puts result.exit_status
```

Run `graphql-schema-change init` to create `.graphql-schema-change.yml`. The
default policy fails on breaking changes or newly invalid operations. Use
`policy.allow` with a reason to approve individual changes, and
`--format github` to surface findings as GitHub Actions annotations. Use
`--locale ja` for Japanese change descriptions.

The tool reports what the supplied operations use. Variable inputs are matched
by type because their runtime values are unavailable. Use only trusted
configuration and Ruby files because `require` and `ruby:` execute Ruby code.

## Compatibility classifications

The checker uses input reachability and output guarantees to classify changes.
The `conservative` profile matches GraphQL.js for optional argument and input
field additions, input-only enum value additions, output-only enum value
removals, and removal of schema-only directives.

The development tests compare supported changes against
`graphql-schema_comparator` 1.2.1. This checker also detects changes to
`@oneOf`, directive repeatability, tracked directive applications, and
`@specifiedBy`. It reports GraphQL schema coordinates such as
`Query.results(first:)`.

## Development

Run `bundle exec rake test build` at this repository's root. This gem has its
own version and accepts Core 0.1.x. Before Core is published, GitHub CI can
use a public Core checkout named by the `GRAPHQL_LINT_CORE_REPOSITORY`
repository variable (`owner/repository`). The release workflow resolves Core
from RubyGems.

## License

MIT.
