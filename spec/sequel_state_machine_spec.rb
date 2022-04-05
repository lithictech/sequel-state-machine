# frozen_string_literal: true

require "sequel"
require "state_machines/macro_methods"
require "state_machines/sequel/spec_helpers"
require "timecop"

RSpec.describe "sequel-state-machine", :db do
  def configure_cls(cls, *args)
    Sequel::Plugins::StateMachine.apply(cls, *args)
    Sequel::Plugins::StateMachine.configure(cls, *args)
    return cls
  end

  before(:all) do
    @db = Sequel.sqlite
    @db.create_table(:users) do
      primary_key :id
    end
    @db.create_table(:charges) do
      primary_key :id
      text :status_col, null: false, default: "created"
      real :total, null: false, default: 0
      text :charge_status, null: false, default: ""
    end
    @db.create_table(:charge_audit_logs) do
      primary_key :id
      timestamp :at, null: false
      text :event, null: false
      text :to_state, null: false
      text :from_state, null: false
      text :reason, null: false, default: ""
      text :messages, default: ""
      foreign_key :charge_id, :charges, null: false, on_delete: :cascade
      index :charge_id
      foreign_key :actor_id, :users, null: true, on_delete: :set_null
    end
    require_relative "spec_models"
  end
  after(:all) do
    @db.disconnect
  end

  describe "configuration" do
    it "can specify the column to use as a kwarg" do
      cls = Class.new do
        extend StateMachines::MacroMethods
        attr_accessor :abc

        state_machine(:xyz) {}
      end
      configure_cls(cls, status_column: :abc)
      cls.include(Sequel::Plugins::StateMachine::InstanceMethods)
      instance = cls.new
      instance.abc = "foo"
      expect(instance.sequel_state_machine_status).to eq("foo")
    end

    it "can specify the column to use as a positional argument" do
      cls = Class.new do
        extend StateMachines::MacroMethods
        attr_accessor :abc

        state_machine(:xyz) {}
      end
      configure_cls(cls, :abc)
      cls.include(Sequel::Plugins::StateMachine::InstanceMethods)
      instance = cls.new
      instance.abc = "foo"
      expect(instance.sequel_state_machine_status).to eq("foo")
    end

    it "can specify the column to use using the legacy _attr field" do
      cls = Class.new do
        extend StateMachines::MacroMethods
        attr_accessor :xyz

        state_machine(:abc) {}

        def _state_value_attr
          return :xyz
        end
      end
      configure_cls(cls)
      cls.include(Sequel::Plugins::StateMachine::InstanceMethods)
      instance = cls.new
      instance.xyz = "foo"
      expect(instance.sequel_state_machine_status).to eq("foo")
    end

    it "defaults to the first state machine status column" do
      cls = Class.new do
        extend StateMachines::MacroMethods
        attr_accessor :abc

        state_machine(:abc) {}
      end
      configure_cls(cls)
      cls.include(Sequel::Plugins::StateMachine::InstanceMethods)
      instance = cls.new
      instance.abc = "foo"
      expect(instance.sequel_state_machine_status).to eq("foo")
    end

    it "errors if there are multiple state machines" do
      cls = Class.new do
        extend StateMachines::MacroMethods
        attr_accessor :abc, :xyz

        state_machine(:abc) {}
        state_machine(:xyz) {}
      end
      configure_cls(cls)
      cls.include(Sequel::Plugins::StateMachine::InstanceMethods)
      expect do
        cls.new.sequel_state_machine_status
      end.to raise_error(Sequel::Plugins::StateMachine::InvalidConfiguration, /with multiple state machines/)
    end

    it "errors if there are no state machines" do
      cls = Class.new do
        extend StateMachines::MacroMethods
        attr_accessor :abc, :xyz
      end
      configure_cls(cls)
      cls.include(Sequel::Plugins::StateMachine::InstanceMethods)
      expect do
        cls.new.sequel_state_machine_status
      end.to raise_error(Sequel::Plugins::StateMachine::InvalidConfiguration, /Model must extend/)
    end
  end

  describe "audit logging" do
    let(:model) { SequelStateMachine::SpecModels::Charge }

    it "logs successful and unsuccessful transitions" do
      o = model.create
      expect(o).to not_transition_on(:charge)
      expect(o).to transition_on(:finalize).to("open")
      expect(o).to transition_on(:charge).to("paid")
      expect(o.audit_logs).to contain_exactly(
        have_attributes(from_state: "pending", to_state: "pending", event: "charge", failed?: true),
        have_attributes(from_state: "pending", to_state: "open", event: "finalize", succeeded?: true),
        have_attributes(from_state: "open", to_state: "paid", event: "charge", succeeded?: true),
      )
      expect(o.audit_logs_dataset.failed.all).to contain_exactly(
        have_attributes(from_state: "pending", event: "charge"),
      )
      expect(o.audit_logs_dataset.succeeded.all).to contain_exactly(
        have_attributes(from_state: "pending", event: "finalize"),
        have_attributes(from_state: "open", event: "charge"),
      )
    end

    it "logs activity during a transition" do
      o = model.create
      def o.finalize
        self.audit("doing a thing")
        return super
      end
      expect(o).to transition_on(:finalize).to("open")
      expect(o.audit_logs).to contain_exactly(
        have_attributes(event: "finalize", messages: "doing a thing", full_message: "doing a thing"),
      )
    end

    it "can include a reason for a failed transition" do
      o = model.create
      def o.finalize
        self.audit("doing a thing", reason: "bad stuff")
        return super
      end
      expect(o).to transition_on(:finalize).to("open")
      expect(o.audit_logs).to contain_exactly(
        have_attributes(event: "finalize", reason: "bad stuff"),
      )
    end

    it "updates the existing audit log for the transition, rather than adding a new one" do
      o = model.create
      o_meta = class << o; self; end
      o_meta.send(:define_method, :charge) do
        self.audit("msg1", reason: "first fail")
        super()
      end
      expect(o).to not_transition_on(:charge)
      expect(o.audit_logs).to contain_exactly(
        have_attributes(event: "charge", reason: "first fail"),
      )

      o_meta.send(:define_method, :charge) do
        self.audit("msg2", reason: "second fail")
        super()
      end
      expect(o).to not_transition_on(:charge)

      expect(o.refresh.audit_logs).to contain_exactly(
        have_attributes(event: "charge", reason: "second fail"),
      )
    end

    it "can create a one-time audit log" do
      o = model.create
      o.audit_one_off("one_off", ["msg1", "msg2"], reason: "rsn")
      expect(o.audit_logs).to contain_exactly(
        have_attributes(
          event: "one_off",
          from_state: "pending",
          to_state: "pending",
          reason: "rsn",
          messages: "msg1\nmsg2",
          full_message: "msg1\nmsg2",
        ),
      )
    end

    it "can create a one-time audit log using a string message" do
      o = model.create
      o.audit_one_off("one_off", "my message")
      expect(o.audit_logs).to contain_exactly(
        have_attributes(
          messages: "my message",
        ),
      )
    end

    describe "actor management" do
      let(:model) { SequelStateMachine::SpecModels::Charge }
      let(:user) { SequelStateMachine::SpecModels::User.create }

      it "captures the current actor during one-offs" do
        o = model.create
        StateMachines::Sequel.set_current_actor(user) do
          o.audit_one_off("one_off", "my message")
        end
        expect(o.audit_logs).to contain_exactly(
          have_attributes(
            messages: "my message",
            actor: be === user,
          ),
        )
      end

      it "captures the current actor for successful transitions" do
        o = model.create
        StateMachines::Sequel.set_current_actor(user) do
          expect(o).to transition_on(:finalize).to("open")
        end
        expect(o).to transition_on(:charge).to("paid")
        expect(o.audit_logs).to contain_exactly(
          have_attributes(event: "finalize", actor: be === user),
          have_attributes(event: "charge", actor: nil),
        )
      end

      it "captures the current actor for successful transitions" do
        o = model.create
        StateMachines::Sequel.set_current_actor(user) do
          expect(o).to not_transition_on(:charge)
        end
        expect(o.audit_logs).to contain_exactly(
          have_attributes(event: "charge", actor: be === user),
        )
      end

      it "updates an existing audit log with the actor" do
        o = model.create
        expect(o).to not_transition_on(:charge)
        expect(o.audit_logs).to contain_exactly(have_attributes(actor: nil))
        StateMachines::Sequel.set_current_actor(user) do
          expect(o).to not_transition_on(:charge)
        end
        expect(o.audit_logs).to contain_exactly(have_attributes(actor: be === user))
      end
    end
  end

  describe "process" do
    let(:model) { SequelStateMachine::SpecModels::Charge }
    let(:instance) { model.create }

    it "saves the model and returns true on a successful transition" do
      expect(instance).to receive(:save_changes)
      expect(instance.process(:finalize)).to be_truthy
    end

    it "saves the model and returns false on an unsuccessful transition" do
      expect(instance).to receive(:save_changes)
      expect(instance.process(:charge)).to be_falsey
    end
  end

  describe "must_process" do
    let(:model) { SequelStateMachine::SpecModels::Charge }
    let(:instance) { model.create }

    it "returns the receiver if the event succeeds" do
      expect(instance.must_process(:finalize)).to be(instance)
    end

    it "errors if processing fails" do
      expect { instance.must_process(:charge) }.to raise_error(StateMachines::Sequel::FailedTransition)
    end

    it "has a nice error" do
      instance.audit("hello")
      instance.audit("newer")
      expect do
        instance.must_process(:charge)
      end.to raise_error(
        "SequelStateMachine::SpecModels::Charge[#{instance.id}] failed to transition on charge: hellonewer",
      )
    end
  end

  describe "process_if" do
    let(:model) { SequelStateMachine::SpecModels::Charge }
    let(:instance) { model.create }

    it "returns the receiver if the block is true and processing succeeds" do
      expect(instance.process_if(:finalize) { true }).to be(instance)
    end

    it "errors if the block is true and processing fails" do
      expect { instance.process_if(:charge) { true } }.to raise_error(StateMachines::Sequel::FailedTransition)
    end

    it "returns the receiver if the block is false" do
      expect(instance.process_if(:charge) { false }).to be(instance)
    end
  end

  describe "valid_state_path_through?" do
    require "sequel/plugins/state_machine"
    let(:test_cls) do
      c = Class.new do
        extend StateMachines::MacroMethods
        include Sequel::Plugins::StateMachine::InstanceMethods
        attr_accessor :state

        state_machine :state, initial: :created do
          state :begin, :middle, :end

          event :move_begin do
            transition begin: :middle
          end

          event :move_middle do
            transition middle: :end
          end

          event :move_any_to_end do
            transition all => :end
          end
        end
      end
      configure_cls(c)
    end

    let(:instance) { test_cls.new }

    it "is true if the given event has a from state equal to the current state" do
      instance.state = "begin"
      expect(instance.valid_state_path_through?(:move_begin)).to be_truthy
      expect(instance.valid_state_path_through?(:move_middle)).to be_falsey
      expect(instance.valid_state_path_through?(:move_any_to_end)).to be_truthy
      expect { instance.valid_state_path_through?(:not_exists) }.to raise_error(/Invalid event/)
      instance.state = "middle"
      expect(instance.valid_state_path_through?(:move_begin)).to be_falsey
      expect(instance.valid_state_path_through?(:move_middle)).to be_truthy
      expect(instance.valid_state_path_through?(:move_any_to_end)).to be_truthy
      instance.state = "end"
      expect(instance.valid_state_path_through?(:move_begin)).to be_falsey
      expect(instance.valid_state_path_through?(:move_middle)).to be_falsey
      expect(instance.valid_state_path_through?(:move_any_to_end)).to be_truthy
    end
  end

  describe "validates_state_machine" do
    let(:model) { SequelStateMachine::SpecModels::Charge }
    let(:instance) { model.new }

    it "is valid for valid states" do
      instance.status_col = "open"
      instance.validates_state_machine
      expect(instance.errors).to be_empty

      instance.status_col = "invalid"
      instance.validates_state_machine
      expect(instance.errors[:status_col].first).to eq(
        "state 'invalid' must be one of (charged, failed, open, paid, pending)",
      )
    end
  end

  describe "timestamp accessors" do
    let(:model) { SequelStateMachine::SpecModels::Charge }
    let(:instance) { model.create }

    it "uses the time of a transition into a state" do
      instance.update(total: 10.1, charge_status: "pending")
      t0 = Time.new(2000, 1, 3, 0, 0, 0, "Z")
      Timecop.freeze(t0) { expect(instance).to transition_on(:finalize).to("open") }
      t1 = Time.new(2000, 1, 3, 1, 0, 0, "Z")
      Timecop.freeze(t1) { expect(instance).to transition_on(:charge).to("charged") }
      t2 = Time.new(2000, 1, 3, 2, 0, 0, "Z")
      instance.update(charge_status: "paid")
      Timecop.freeze(t2) { expect(instance).to transition_on(:charge).to("paid") }
      t3 = Time.new(2000, 1, 3, 3, 0, 0, "Z")
      Timecop.freeze(t3) { expect(instance).to transition_on(:set_failed).to("failed") }
      expect(instance).to have_attributes(
        finalized_at: droptz(t0),
        charged_at: droptz(t1),
        paid_at: droptz(t2),
        failed_at: droptz(t3),
      )
    end

    it "uses the latest transition" do
      instance.update(total: 10.1)

      t0 = Time.new(2000, 1, 3, 0, 0, 0, "Z")
      Timecop.freeze(t0) { expect(instance).to transition_on(:finalize).to("open") }
      expect(instance).to have_attributes(finalized_at: droptz(t0))

      instance.update(status_col: "pending")
      t1 = Time.new(2000, 1, 3, 5, 0, 0, "Z")
      Timecop.freeze(t1) { expect(instance).to transition_on(:finalize).to("open") }
      expect(instance.refresh).to have_attributes(finalized_at: droptz(t1))
    end
  end

  describe "shared examples" do
    it_behaves_like "a state machine with audit logging", :finalize, "open" do
      let(:machine) { SequelStateMachine::SpecModels::Charge.create }
    end
  end

  def droptz(t)
    return Time.new(t.year, t.month, t.day, t.hour, t.min, t.sec, nil)
  end
end
