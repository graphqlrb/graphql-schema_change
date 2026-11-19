# frozen_string_literal: true

require "graphql/lint_core"
require_relative "schema_change/version"
require_relative "schema_change/catalog"
require_relative "schema_change/type_ref_compat"
require_relative "schema_change/change"
require_relative "schema_change/diff"
require_relative "schema_change/impact"
require_relative "schema_change/policy"
require_relative "schema_change/result"
require_relative "schema_change/runner"

module GraphQL
  module SchemaChange
    @policy_hooks = [].freeze

    # @api public
    def self.check(old: nil, new: nil, documents: nil, config: nil, overrides: {})
      explicit = {"old" => old, "new" => new, "documents" => documents}.compact
      run(config: config, overrides: overrides.transform_keys(&:to_s).merge(explicit))
    end

    # @api public
    def self.run(config: nil, overrides: {})
      Runner.new.run(config: config, overrides: overrides)
    end

    # @api public
    def self.configure
      yield self
    end

    # @api public
    def self.policy_hook(&hook)
      raise ArgumentError, "A policy hook block is required." unless hook

      @policy_hooks = (@policy_hooks + [hook]).freeze
    end

    def self.policy_hooks = @policy_hooks
  end
end
