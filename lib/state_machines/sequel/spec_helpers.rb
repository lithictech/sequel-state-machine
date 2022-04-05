# frozen_string_literal: true

require "rspec"

RSpec::Matchers.define :transition_on do |event|
  match do |receiver|
    raise ArgumentError, "must use :to to provide a target state" if (@to || "").to_s.empty?
    raise ArgumentError, "must use :of_machine for use with multiple state machines" if
      @machine.nil? && receiver.class.state_machines.length > 1
    receiver.send(event, *@args)
    @to == receiver.send(@machine || :sequel_state_machine_status)
  end

  chain :of_machine do |col|
    @machine = col
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
    msg =
      if @to == receiver.state_machine_status
        "expected that event #{event} would transition, but did not"
      else
        "expected that event #{event} would transition to #{@to} but is #{receiver.state_machine_status}"
      end
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
    "expected that event #{event} would not transition, but did and is now #{receiver.state_machine_status}"
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
