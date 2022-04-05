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
          actor: :actor,
        }.freeze,
      }.freeze
      def self.configure(model, opts=DEFAULT_OPTIONS)
        opts = DEFAULT_OPTIONS.merge(opts)
        colmap = opts[:column_mappings]
        actor_key_mismatch = (colmap.key?(:actor) && !colmap.key?(:actor_id)) ||
          (!colmap.key?(:actor) && colmap.key?(:actor_id))
        if actor_key_mismatch
          msg = "Remapping columns :actor and :actor_id must both be supplied"
          raise Sequel::Plugins::StateMachine::InvalidConfiguration, msg
        end
        model.state_machine_column_mappings = colmap
        msgarray = opts[:messages_supports_array] || true
        if msgarray == :undefined
          msgcol = model.state_machine_column_mappings[:messages]
          if model.db_schema && model.db_schema[msgcol]
            dbt = model.db_schema[msgcol][:db_type]
            msgarray = dbt.include?("json") || dbt.include?("[]")
          end
        end
        model.state_machine_messages_supports_array = msgarray
      end

      module ClassMethods
        attr_accessor :state_machine_messages_supports_array, :state_machine_column_mappings
      end

      module DatasetMethods
        def failed
          colmap = self.model.state_machine_column_mappings
          tostate_col = colmap[:to_state]
          fromstate_col = colmap[:from_state]
          return self.where(tostate_col => fromstate_col)
        end

        def succeeded
          colmap = self.model.state_machine_column_mappings
          tostate_col = colmap[:to_state]
          fromstate_col = colmap[:from_state]
          return self.exclude(tostate_col => fromstate_col)
        end
      end

      module InstanceMethods
        def failed?
          from_state = self.sequel_state_machine_get(:from_state)
          to_state = self.sequel_state_machine_get(:to_state)
          return from_state == to_state
        end

        def succeeded?
          return !self.failed?
        end

        def full_message
          msg = self.sequel_state_machine_get(:messages)
          return self.class.state_machine_messages_supports_array ? msg.join(", ") : msg
        end

        def sequel_state_machine_get(unmapped)
          return self[self.class.state_machine_column_mappings[unmapped]]
        end

        def sequel_state_machine_set(unmapped, value)
          self[self.class.state_machine_column_mappings[unmapped]] = value
        end

        def sequel_state_machine_map_columns(**kw)
          mappings = self.class.state_machine_column_mappings
          return kw.transform_keys { |k| mappings[k] or raise KeyError, "field #{k} unmapped in #{mappings}" }
        end
      end
    end
  end
end
