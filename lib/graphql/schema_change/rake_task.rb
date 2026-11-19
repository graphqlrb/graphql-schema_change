# frozen_string_literal: true

require "rake/tasklib"
require "graphql/schema_change/cli"

module GraphQL
  module SchemaChange
    # @api public
    class RakeTask < Rake::TaskLib
      attr_accessor :config

      def initialize(name = "graphql:schema_change")
        yield self if block_given?
        desc "Check GraphQL schema compatibility"
        task name do
          arguments = config ? ["check", "--config", config] : ["check"]
          status = CLI.run(arguments)
          abort "GraphQL schema change check exited with status #{status}." unless status.zero?
        end
      end
    end
  end
end
