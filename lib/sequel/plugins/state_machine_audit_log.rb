# frozen_string_literal: true

require "sequel"
require "sequel/model"

module Sequel
  module Plugins
    module StateMachineAuditLog
      DEFAULT_OPTIONS = {
        messages_supports_array: :undefined,
        column_mappings: {
          at: :at,
          event: :event,
          to_state: :to_state,
          from_state: :from_state,
          reason: :reason,
          messages: :messages,
          actor_id: :actor_id,
        }.freeze,
      }.freeze
      def self.configure(model, opts=DEFAULT_OPTIONS)
        opts = DEFAULT_OPTIONS.merge(opts)
        model.state_machine_column_mappings = opts[:column_mappings]
        msgarray = opts[:messages_supports_array] || true
        if msgarray == :undefined
          msgcol = model.state_machine_column_mappings[:messages]
          dbt = model.db_schema[msgcol][:db_type]
          msgarray = dbt.include?("json") || dbt.include?("[]")
        end
        model.state_machine_messages_supports_array = msgarray
      end

      module ClassMethods
        attr_accessor :state_machine_messages_supports_array, :state_machine_column_mappings
      end

      module DatasetMethods
        def failed
          colmap = self.state_machine_column_mappings
          tostate_col = colmap[:to_state]
          fromstate_col = colmap[:from_state]
          return self.where(tostate_col => fromstate_col)
        end

        def succeeded
          colmap = self.state_machine_column_mappings
          tostate_col = colmap[:to_state]
          fromstate_col = colmap[:from_state]
          return self.exclude(tostate_col => fromstate_col)
        end
      end

      module InstanceMethods
        def failed?
          colmap = self.state_machine_column_mappings
          return colmap[:from_state] == colmap[:to_state]
        end

        def succeeded?
          colmap = self.state_machine_column_mappings
          return colmap[:from_state] != colmap[:to_state]
        end
      end
    end
  end
end
