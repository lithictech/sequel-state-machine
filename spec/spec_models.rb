# frozen_string_literal: true

require "state_machines"

# Type that can be used for unit testing state machine helpers.
module SequelStateMachine
  module SpecModels
    class Charge < Sequel::Model(:charges)
      extend StateMachines::MacroMethods
      plugin :state_machine

      one_to_many :audit_logs, class: "SequelStateMachine::SpecModels::ChargeAuditLog", order: Sequel.desc(:at)

      state_machine :status_col, initial: :pending do
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

        event :reset do
          transition failed: :pending
        end

        after_transition(&:commit_audit_log)
        after_failure(&:commit_audit_log)
      end

      timestamp_accessors(
        [
          [{to: "open"}, :finalized_at],
          [{event: "charge", from: "open", to: "charged"}, :charged_at],
          [{to: "paid"}, :paid_at],
          [{to: "failed"}, :failed_at],
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

    class MultiMachine < Sequel::Model(:multi_machines)
      extend StateMachines::MacroMethods
      plugin :state_machine
      one_to_many :audit_logs, class: "SequelStateMachine::SpecModels::MultiMachineAuditLog"
      state_machine :machine1, initial: :m1state1 do
        state :m1state1,
              :m1state2,
              :m1state3

        event :gom1state2 do
          transition m1state1: :m1state2
        end
        event :gom1state3 do
          transition m1state2: :m1state3
        end
        after_transition(&:commit_audit_log)
        after_failure(&:commit_audit_log)
      end
      state_machine :machine2, initial: :m2state1 do
        state :m2state1,
              :m2state2,
              :m2state3

        event :gom2state2 do
          transition m2state1: :m2state2
        end
        event :gom2state3 do
          transition m2state2: :m2state3
        end
        after_transition(&:commit_audit_log)
        after_failure(&:commit_audit_log)
      end

      timestamp_accessors(
        [
          [{to: "m1state2"}, :m1state2_at],
          [{to: "m1state3"}, :m1state3_at],
          [{to: "m2state2"}, :m2state2_at],
          [{to: "m2state3"}, :m2state3_at],
        ],
      )
      def validate
        super
        self.validates_state_machine(machine: :machine1)
        self.validates_state_machine(machine: :machine2)
      end
    end

    class MultiMachineAuditLog < Sequel::Model(:multi_machine_audit_logs)
      plugin :state_machine_audit_log
      many_to_one :multi_machine, class: "SequelStateMachine::SpecModels::MultiMachine"
      many_to_one :actor, class: "SequelStateMachine::SpecModels::User"
    end
  end
end
