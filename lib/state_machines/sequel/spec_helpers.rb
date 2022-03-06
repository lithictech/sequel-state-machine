# frozen_string_literal: true

require "rspec"

RSpec::Matchers.define :transition_on do |event|
  match do |receiver|
    raise 'must provide a "to" state' if (@to || "").to_s.empty?
    receiver.send(event, *@args)
    @to == receiver.status
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
      if @to == receiver.status
        "expected that event #{event} would transition, but did not"
      else
        "expected that event #{event} would transition to #{@to} but is #{receiver.status}"
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
    "expected that event #{event} would not transition, but did and is now #{receiver.status}"
  end
end

RSpec.shared_examples "a state machine with audit logging" do |event, to_state|
  it "logs transitions" do
    expect(machine).to transition_on(event).to(to_state)
    expect(machine.audit_logs).to contain_exactly(
      have_attributes(to_state: to_state, event: event.to_s),
    )
  end
end
