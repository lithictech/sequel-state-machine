# frozen_string_literal: true

require "state_machines"

# Type that can be used for unit testing state machine helpers.
module SequelStateMachine
  module SpecModels
    class Charge < Sequel::Model(:charges)
      extend StateMachines::MacroMethods
      plugin :state_machine

      one_to_many :audit_logs, class: "SequelStateMachine::SpecModels::ChargeAuditLog", order: Sequel.desc(:at)

      state_machine :status, initial: :pending do
        state :pending,
              :open,
              :charged,
              :paid,
              :failed

        event :finalize do
          transition pending: :open
        end

        event :charge do
          transition open: :paid, if: :total_zero?
          transition [:open, :charged] => :paid, if: :charge_paid?
          transition [:open, :charged] => :failed, if: :charge_failed?
          transition open: :charged, if: :charge_in_progress?
        end

        event :set_failed do
          transition any => :failed
        end

        after_transition(&:commit_audit_log)
        after_failure(&:commit_audit_log)
      end

      timestamp_accessors(
        [
          [{event: "charge", from: "open", to: "charged"}, :charged_at],
          [{to: "paid"}, :paid_at],
        ],
      )

      def total_zero?
        return self.total.zero?
      end

      def charge_paid?
        return self.charge_status == "paid"
      end

      def charge_in_progress?
        return self.charge_status == "pending"
      end

      def charge_failed?
        return self.charge_status == "failed"
      end

      def validate
        super
        self.validates_state_machine
      end
    end

    class User < Sequel::Model(:users)
    end

    class ChargeAuditLog < Sequel::Model(:charge_audit_logs)
      plugin :state_machine_audit_log

      many_to_one :charge, class: "SequelStateMachine::SpecModels::Charge"
      many_to_one :actor, class: "SequelStateMachine::SpecModels::User"
    end
  end
end
