# frozen_string_literal: true

module StateMachines
  module Sequel
    class CurrentActorAlreadySet < StateMachines::Error; end

    class FailedTransition < StateMachines::Error
      attr_reader :event, :object, :audit_log

      def initialize(obj, event)
        @event = event
        @object = obj
        msg = "#{obj.class}[#{obj.id}] failed to transition on #{event}"
        if obj.respond_to?(:audit_logs) && obj.audit_logs.present?
          @audit_log = obj.audit_logs.max_by(&:id)
          msg += ": #{@audit_log.messages.last}"
        end
        super(msg)
      end
    end

    class << self
      attr_accessor :structured_logging

      # Proc called with [instance, level, message, params].
      # By default, logs to `instance.logger` if it instance responds to :logger.
      # If structured_logging is true, the message will be an 'event' without any dynamic info,
      # if false, the params will be rendered into the message so are suitable for unstructured logging.
      attr_accessor :log_callback

      def reset_logging
        self.log_callback = lambda { |instance, level, msg, _params|
          instance.respond_to?(:logger) ? instance.logger.send(level, msg) : nil
        }
        self.structured_logging = false
      end

      def log(instance, level, message, params)
        if self.structured_logging
          paramstr = params.map { |k, v| "#{k}=#{v}" }.join(" ")
          message = "#{message} #{paramstr}"
        end
        self.log_callback[instance, level, message, params]
      end

      def current_actor
        return Thread.current[:sequel_state_machines_current_actor]
      end

      def set_current_actor(admin, &block)
        raise CurrentActorAlreadySet, "already set to: #{self.current_actor}" if !admin.nil? && !self.current_actor.nil?
        Thread.current[:sequel_state_machines_current_actor] = admin
        return if block.nil?
        begin
          yield
        ensure
          Thread.current[:sequel_state_machines_current_actor] = nil
        end
      end
    end
  end
end

StateMachines::Sequel.reset_logging
