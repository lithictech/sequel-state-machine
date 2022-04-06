# frozen_string_literal: true

require "rspec"

module StateMachines
  module Sequel
    module SpecHelpers
      module_function def find_state_machine(receiver, event)
        state_machine = receiver.class.state_machines.values.find { |sm| sm.events[event] }
        raise ArgumentError, "receiver #{receiver.class} has no state machine for event #{event}" unless state_machine
        return state_machine
      end

      RSpec::Matchers.define :transition_on do |event|
        match do |receiver|
          raise ArgumentError, "must use :to to provide a target state" if (@to || "").to_s.empty?
          machine = StateMachines::Sequel::SpecHelpers.find_state_machine(receiver, event)
          receiver.send(event, *@args)
          current_status = receiver.send(machine.attribute)
          @to == current_status
        end

        chain :to do |to_state|
          @to = to_state
        end

        chain :with do |*args|
          @args = args
        end

        chain :audit do
          @audit = true
        end

        failure_message do |receiver|
          status = receiver.send(StateMachines::Sequel::SpecHelpers.find_state_machine(receiver, event).attribute)
          msg =
            "expected that event #{event} would transition to #{@to} but is #{status}"
          (msg += "\n#{receiver.audit_logs.map(&:inspect).join("\n")}") if @audit
          msg
        end
      end

      RSpec::Matchers.define :not_transition_on do |event|
        match do |receiver|
          !receiver.send(event, *@args)
        end

        chain :with do |*args|
          @args = args
        end

        failure_message do |receiver|
          status = receiver.send(StateMachines::Sequel::SpecHelpers.find_state_machine(receiver, event).attribute)
          "expected that event #{event} would not transition, but did and is now #{status}"
        end
      end
    end
  end
end

RSpec.shared_examples "a state machine with audit logging" do |event, to_state|
  let(:machine) { raise NotImplementedError, "must override let(:machine)" }
  it "logs transitions" do
    expect(machine).to transition_on(event).to(to_state)
    expect(machine.audit_logs).to contain_exactly(
      have_attributes(to_state: to_state, event: event.to_s),
    )
  end
end
