# frozen_string_literal: true

require "sequel"
require "sequel/model"
require "state_machines/sequel"

module Sequel
  module Plugins
    module StateMachine
      class InvalidConfiguration < RuntimeError; end

      def self.apply(_model, _opts={})
        nil
      end

      def self.configure(model, opts={})
        (opts = {status_column: opts}) if opts.is_a?(Symbol)
        model.instance_eval do
          # See state_machine_status_column.
          # We must defer defaulting the value in case the plugin
          # comes ahead of the state  machine (we can see a valid state machine,
          # but the attribute/name will always be :state, due to some configuration
          # order of operations).
          @sequel_state_machine_status_column = opts[:status_column] if opts[:status_column]
          @sequel_state_machine_audit_logs_association = opts[:audit_logs_association] || :audit_logs
        end
      end

      module InstanceMethods
        private def state_machine_status_column
          col = self.class.instance_variable_get(:@sequel_state_machine_status_column)
          return col unless col.nil?
          if self.respond_to?(:_state_value_attr)
            self.class.instance_variable_set(:@sequel_state_machine_status_column, self._state_value_attr)
            return self._state_value_attr
          end
          if !self.class.respond_to?(:state_machines) || self.class.state_machines.empty?
            msg = "Model must extend StateMachines::MacroMethods and have one state_machine."
            raise InvalidConfiguration, msg
          end
          if self.class.state_machines.length > 1
            msg = "Cannot use sequel-state-machine with multiple state machines. " \
                  "Please file an issue at https://github.com/lithictech/sequel-state-machine/issues " \
                  "if you need this capability."
            raise InvalidConfiguration, msg
          end
          self.class.instance_variable_set(:@sequel_state_machine_status_column, self.class.state_machine.attribute)
        end

        private def state_machine_status
          return self.send(self.state_machine_status_column)
        end

        def sequel_state_machine_status
          return state_machine_status
        end

        def new_audit_log
          assoc_name = self.class.instance_variable_get(:@sequel_state_machine_audit_logs_association)
          unless (audit_log_assoc = self.class.association_reflections[assoc_name])
            msg = "Association for audit logs '#{assoc_name}' does not exist. " \
                  "Your model must have 'one_to_many :audit_logs' for its audit log lines, " \
                  "or pass the :audit_logs_association parameter to the plugin to define its association name."
            raise InvalidConfiguration, msg
          end
          audit_log_cls = audit_log_assoc[:class] || Kernel.const_get(audit_log_assoc[:class_name])
          return audit_log_cls.new
        end

        def current_audit_log
          if @current_audit_log.nil?
            StateMachines::Sequel.log(self, :debug, "preparing_audit_log", {})
            @current_audit_log = self.new_audit_log
            @current_audit_log.sequel_state_machine_set(:reason, "")
          end
          return @current_audit_log
        end

        def commit_audit_log(transition)
          StateMachines::Sequel.log(self, :debug, "committing_audit_log", {transition: transition})
          current = self.current_audit_log

          last_saved = self.audit_logs.find do |a|
            a.sequel_state_machine_get(:event) == transition.event.to_s &&
              a.sequel_state_machine_get(:from_state) == transition.from &&
              a.sequel_state_machine_get(:to_state) == transition.to
          end
          if last_saved
            StateMachines::Sequel.log(self, :debug, "updating_audit_log", {audit_log_id: last_saved.id})
            last_saved.update(**last_saved.sequel_state_machine_map_columns(
              at: Time.now,
              actor: StateMachines::Sequel.current_actor,
              messages: current.messages,
              reason: current.reason,
            ))
          else
            StateMachines::Sequel.log(self, :debug, "creating_audit_log", {})
            current.set(**current.sequel_state_machine_map_columns(
              at: Time.now,
              actor: StateMachines::Sequel.current_actor,
              event: transition.event.to_s,
              from_state: transition.from,
              to_state: transition.to,
            ))
            self.add_audit_log(current)
          end
          @current_audit_log = nil
        end

        def audit(message, reason: nil)
          audlog = self.current_audit_log
          if audlog.class.state_machine_messages_supports_array
            audlog.messages ||= []
            audlog.messages << message
          else
            audlog.messages ||= ""
            audlog.messages += (audlog.messages.empty? ? message : (message + "\n"))
          end
          audlog.reason = reason if reason
        end

        def audit_one_off(event, messages, reason: nil)
          messages = [messages] unless messages.respond_to?(:to_ary)
          audlog = self.new_audit_log
          audlog.set(audlog.sequel_state_machine_map_columns(
                       at: Time.now,
                       event: event,
                       from_state: self.state_machine_status,
                       to_state: self.state_machine_status,
                       messages: audlog.class.state_machine_messages_supports_array ? messages : messages.join("\n"),
                       reason: reason || "",
                       actor: StateMachines::Sequel.current_actor,
                     ))
          return self.add_audit_log(audlog)
        end

        # Send event with arguments inside of a transaction, save the changes to the receiver,
        # and return the transition result.
        # Used to ensure the event processing happens in a transaction and the receiver is saved.
        def process(event, *args)
          self.db.transaction do
            self.lock!
            result = self.send(event, *args)
            self.save_changes
            return result
          end
        end

        # Same as process, but raises an error if the transition fails.
        def must_process(event, *args)
          success = self.process(event, *args)
          raise StateMachines::Sequel::FailedTransition.new(self, event) unless success
          return self
        end

        # Same as must_process, but takes a lock,
        # and calls the given block, only doing actual processing if the block returns true.
        # If the block returns false, it acts as a success.
        # Used to avoid issues concurrently processing the same object through the same state.
        def process_if(event, *args)
          self.db.transaction do
            self.lock!
            return self unless yield(self)
            return self.must_process(event, *args)
          end
        end

        # Return true if the given event can be transitioned into by the current state.
        def valid_state_path_through?(event)
          current_state_str = self.state_machine_status.to_s
          current_state_sym = current_state_str.to_sym
          event_obj = self.class.state_machine.events[event] or raise "Invalid event #{event}"
          event_obj.branches.each do |branch|
            branch.state_requirements.each do |state_req|
              next unless (from = state_req[:from])
              return true if from.matches?(current_state_str) || from.matches?(current_state_sym)
            end
          end
          return false
        end

        def validates_state_machine
          states = self.class.state_machine.states.map(&:value)
          state = self.state_machine_status
          return if states.include?(state)
          self.errors.add(self.state_machine_status_column,
                          "state '#{state}' must be one of (#{states.sort.join(', ')})",)
        end
      end

      module ClassMethods
        def timestamp_accessors(events_and_accessors)
          events_and_accessors.each do |(ev, acc)|
            self.timestamp_accessor(ev, acc)
          end
        end

        # Register the timestamp access for an event.
        # A timestamp accessor reads when a certain transition happened
        # by looking at the timestamp of the successful transition into that state.
        #
        # The event can be just the event name, or a hash of {event: <event method symbol>, from: <state name>},
        # used when a single event can cause multiple transitions.
        def timestamp_accessor(event, accessor)
          define_method(accessor) do
            event = {event: event} if event.is_a?(String)
            audit = self.audit_logs.select(&:succeeded?).find do |a|
              ev_match = event[:event].nil? || event[:event] == a.event
              from_match = event[:from].nil? || event[:from] == a.from_state
              to_match = event[:to].nil? || event[:to] == a.to_state
              ev_match && from_match && to_match
            end
            return audit&.at
          end
        end
      end
    end
  end
end
