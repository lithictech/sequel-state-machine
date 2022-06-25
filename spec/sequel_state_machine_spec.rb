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
    @db.create_table(:multi_machines) do
      primary_key :id
      text :machine1, null: false
      text :machine2, null: false
    end
    @db.create_table(:multi_machine_audit_logs) do
      primary_key :id
      timestamp :at, null: false
      text :event, null: false
      text :to_state, null: false
      text :from_state, null: false
      text :reason, null: false, default: ""
      text :messages, default: ""
      text :machine_name, null: false
      foreign_key :multi_machine_id, :multi_machines, null: false, on_delete: :cascade
      index :multi_machine_id
      foreign_key :actor_id, :users, null: true, on_delete: :set_null
    end
    require_relative "spec_models"
  end
  after(:all) do
    @db.disconnect
  end

  let(:audit_log_cls) do
    Class.new(Sequel::Model) do
      plugin :state_machine_audit_log
      attr_accessor :at,
                    :event,
                    :to_state,
                    :from_state,
                    :reason,
                    :messages,
                    :actor_id,
                    :actor,
                    :machine_name
    end
  end

  it "has a version" do
    expect(StateMachines::Sequel::VERSION).to be_a(String)
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
      end.to raise_error(ArgumentError, /must provide the :machine/)
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

    it "can specify the audit log relationship name" do
      logcls = audit_log_cls
      cls = Class.new(Sequel::Model) do
        plugin :state_machine, audit_logs_association: :audit_lines
        extend StateMachines::MacroMethods
        state_machine(:abc) {}
        one_to_many :audit_lines, class: logcls
      end
      instance = cls.new
      instance.abc = "foo"
      expect(instance.sequel_state_machine_status).to eq("foo")
      expect(instance.current_audit_log).to be_a(audit_log_cls)
    end

    it "errors clearly if the audit relationship does not exist" do
      cls = Class.new(Sequel::Model) do
        plugin :state_machine
        extend StateMachines::MacroMethods
        state_machine(:abc) {}
      end
      expect do
        cls.new.current_audit_log
      end.to raise_error(Sequel::Plugins::StateMachine::InvalidConfiguration, /Association for audit logs/)
    end

    it "defaults the audit log relationship to 'audit_logs'" do
      logcls = audit_log_cls
      cls = Class.new(Sequel::Model) do
        plugin :state_machine
        extend StateMachines::MacroMethods
        state_machine(:abc) {}
        one_to_many :audit_logs, class: logcls
      end
      instance = cls.new
      instance.abc = "foo"
      expect(instance.sequel_state_machine_status).to eq("foo")
      expect(instance.current_audit_log).to be_a(audit_log_cls)
    end

    it "errors if audit logs do not have a machine_name field" do
      logcls = Class.new(Sequel::Model) do
        plugin :state_machine_audit_log
        attr_accessor :at,
                      :event,
                      :to_state,
                      :from_state,
                      :reason,
                      :messages,
                      :actor_id,
                      :actor
      end
      cls = Class.new(Sequel::Model) do
        plugin :state_machine
        extend StateMachines::MacroMethods
        state_machine(:abc) {}
        one_to_many :audit_logs, class: logcls
      end
      instance = cls.new
      line = instance.audit("hello", reason: "rzn")
      expect(line).to have_attributes(reason: "rzn", messages: ["hello"])
    end

    it "can override audit_logs, new_audit_log, and add_audit_log" do
      logcls = audit_log_cls
      cls = Class.new(Sequel::Model) do
        plugin :state_machine
        extend StateMachines::MacroMethods
        state_machine(:abc) {}
        attr_accessor :audit_logs

        define_method(:audit_logs) do
          @audit_logs ||= []
          return @audit_logs
        end
        define_method(:new_audit_log) do
          return logcls.new
        end
        define_method(:add_audit_log) do |lg|
          self.audit_logs << lg
        end
      end
      instance = cls.new
      expect(instance.audit_logs).to be_empty
      current = instance.current_audit_log
      expect(current).to be_a(audit_log_cls)
      instance.audit_one_off("hello", [])
      expect(instance.audit_logs).to contain_exactly(have_attributes(event: "hello"))
    end

    it "can specify multiple arguments" do
      logcls = audit_log_cls
      cls = Class.new(Sequel::Model) do
        plugin :state_machine, status_column: :xyz, audit_logs_association: :audit_lines
        extend StateMachines::MacroMethods
        attr_accessor :abc, :xyz

        state_machine(:abc) {}
        one_to_many :audit_lines, class: logcls
      end
      instance = cls.new
      instance.xyz = "foo"
      expect(instance.sequel_state_machine_status).to eq("foo")
      expect(instance.current_audit_log).to be_a(audit_log_cls)
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

    it "can map column names as part of plugin config" do
      logcls = Class.new(Sequel::Model) do
        plugin :state_machine_audit_log, column_mappings: {
          at: :at2,
          event: :event2,
          to_state: :to_state2,
          from_state: :from_state2,
          reason: :reason2,
          messages: :messages2,
          actor_id: :actor_id2,
          actor: :actor2,
        }
        attr_accessor :at2,
                      :event2,
                      :to_state2,
                      :from_state2,
                      :reason2,
                      :messages2,
                      :actor_id2,
                      :actor2
      end
      cls = Class.new(Sequel::Model) do
        plugin :state_machine
        extend StateMachines::MacroMethods
        state_machine(:abc) {}
        one_to_many :audit_logs, class: logcls

        def add_audit_log(x)
          return x
        end
      end
      instance = cls.new
      log = instance.audit_one_off("hello", "msg")
      expect(log).to have_attributes(reason2: "", messages2: ["msg"], event2: "hello")
    end

    it "can partially map columns" do
      logcls = Class.new(Sequel::Model) do
        plugin :state_machine_audit_log, column_mappings: {
          at: :at2,
          event: :event2,
        }
        attr_accessor :at2,
                      :event2,
                      :to_state,
                      :from_state,
                      :reason,
                      :messages,
                      :actor_id,
                      :actor,
                      :machine_name
      end
      cls = Class.new(Sequel::Model) do
        plugin :state_machine
        extend StateMachines::MacroMethods
        state_machine(:abc) {}
        one_to_many :audit_logs, class: logcls

        def add_audit_log(x)
          return x
        end
      end
      instance = cls.new
      log = instance.audit_one_off("hello", "msg")
      expect(log).to have_attributes(messages: ["msg"], event2: "hello")
    end

    it "errors if the column remapping includes only one or the other of actor and actor_id" do
      expect do
        Class.new(Sequel::Model) do
          plugin :state_machine_audit_log, column_mappings: {
            actor_id: :actor_id2,
          }
        end
      end.to raise_error(Sequel::Plugins::StateMachine::InvalidConfiguration, /Remapping columns :actor and /)
      expect do
        Class.new(Sequel::Model) do
          plugin :state_machine_audit_log, column_mappings: {
            actor: :actor2,
          }
        end
      end.to raise_error(Sequel::Plugins::StateMachine::InvalidConfiguration, /Remapping columns :actor and /)
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

      expect do
        instance.valid_state_path_through?(:invalid)
      end.to raise_error(
        ArgumentError,
        "Invalid event invalid (available state events: move_begin, move_middle, move_any_to_end)",
      )
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

  describe "multiple state machines" do
    let(:model) { SequelStateMachine::SpecModels::MultiMachine }

    it "can transition and audit log" do
      o = model.create
      expect(o).to not_transition_on(:gom1state3)
      expect(o).to transition_on(:gom1state2).to("m1state2")
      expect(o).to not_transition_on(:gom2state3)
      expect(o).to transition_on(:gom2state2).to("m2state2")
      o.audit("msg1", machine: :machine2)
      expect(o).to transition_on(:gom2state3).to("m2state3")
      o.audit_one_off("hello2", "some msg", machine: "machine2")
      expect(o).to transition_on(:gom1state3).to("m1state3")
      o.audit_one_off("hello1", "some msg", machine: "machine1")

      expect(o.audit_logs).to contain_exactly(
        have_attributes(event: "gom1state3", from_state: "m1state1", to_state: "m1state1"),
        have_attributes(event: "gom1state2", from_state: "m1state1", to_state: "m1state2"),
        have_attributes(event: "gom2state3", from_state: "m2state1", to_state: "m2state1"),
        have_attributes(event: "gom2state2", from_state: "m2state1", to_state: "m2state2"),
        have_attributes(event: "gom2state3", from_state: "m2state2", to_state: "m2state3", messages: include("msg1")),
        have_attributes(event: "hello2", from_state: "m2state3", to_state: "m2state3"),
        have_attributes(event: "gom1state3", from_state: "m1state2", to_state: "m1state3"),
        have_attributes(event: "hello1", from_state: "m1state3", to_state: "m1state3"),
      )

      expect(o.audit_logs_for(:machine1)).to contain_exactly(
        have_attributes(event: "gom1state3", from_state: "m1state1", to_state: "m1state1"),
        have_attributes(event: "gom1state2", from_state: "m1state1", to_state: "m1state2"),
        have_attributes(event: "gom1state3", from_state: "m1state2", to_state: "m1state3"),
        have_attributes(event: "hello1", from_state: "m1state3", to_state: "m1state3"),
      )
      expect(o.audit_logs_for(:machine2)).to contain_exactly(
        have_attributes(event: "gom2state3", from_state: "m2state1", to_state: "m2state1"),
        have_attributes(event: "gom2state2", from_state: "m2state1", to_state: "m2state2"),
        have_attributes(event: "gom2state3", from_state: "m2state2", to_state: "m2state3"),
        have_attributes(event: "hello2", from_state: "m2state3", to_state: "m2state3"),
      )
    end

    it "can use timestamp accessors" do
      o = model.create
      t0 = Time.new(2000, 1, 3, 0, 0, 0, "Z")
      Timecop.freeze(t0) { expect(o).to transition_on(:gom1state2).to("m1state2") }
      t1 = Time.new(2000, 1, 3, 1, 0, 0, "Z")
      Timecop.freeze(t1) { expect(o).to transition_on(:gom1state3).to("m1state3") }
      t2 = Time.new(2000, 1, 3, 2, 0, 0, "Z")
      Timecop.freeze(t2) { expect(o).to transition_on(:gom2state2).to("m2state2") }
      t3 = Time.new(2000, 1, 3, 3, 0, 0, "Z")
      Timecop.freeze(t3) { expect(o).to transition_on(:gom2state3).to("m2state3") }
      expect(o).to have_attributes(
        m1state2_at: droptz(t0),
        m1state3_at: droptz(t1),
        m2state2_at: droptz(t2),
        m2state3_at: droptz(t3),
      )
    end

    it "can use process methods" do
      o = model.create
      expect(o.process(:gom1state3)).to be_falsey
      expect(o.process(:gom1state2)).to be_truthy
      expect(o.process(:gom1state3)).to be_truthy
    end

    it "can use valid_state_path_through" do
      o = model.create
      expect(o.valid_state_path_through?(:gom1state2, machine: :machine1)).to be_truthy
      expect(o.valid_state_path_through?(:gom1state3, machine: :machine1)).to be_falsey
      expect(o).to transition_on(:gom1state2).to("m1state2")
      expect(o.valid_state_path_through?(:gom1state3, machine: :machine1)).to be_truthy

      expect(o.valid_state_path_through?(:gom2state2, machine: :machine2)).to be_truthy
      expect(o.valid_state_path_through?(:gom2state3, machine: :machine2)).to be_falsey
      expect(o).to transition_on(:gom2state2).to("m2state2")
      expect(o.valid_state_path_through?(:gom2state3, machine: :machine2)).to be_truthy
    end

    it "can use state machine validations" do
      o = model.new
      o.machine1 = "m1state2"
      o.validates_state_machine(machine: :machine1)
      expect(o.errors).to be_empty

      o.machine1 = "invalid"
      o.validates_state_machine(machine: :machine1)
      expect(o.errors[:machine1].first).to eq(
        "state 'invalid' must be one of (m1state1, m1state2, m1state3)",
      )
    end
  end

  describe "spec helpers" do
    describe "transition_on" do
      let(:instance) { SequelStateMachine::SpecModels::Charge.create }

      it "succeeds on a successful transition" do
        expect(instance).to transition_on(:finalize).to("open")
      end
      it "can accept arguments" do
        expect(instance).to receive(:finalize).with(1).and_call_original
        expect(instance).to transition_on(:finalize).with(1).to("open")
      end
      it "errors if the transition fails" do
        expect do
          expect(instance).to transition_on(:charge).to("charged")
        end.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          "expected that event charge would transition to charged but is pending",
        )
      end
      it "errors if the transition is incorrect" do
        instance.status_col = "open"
        expect do
          expect(instance).to transition_on(:charge).to("pending")
        end.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          "expected that event charge would transition to pending but is paid",
        )
      end
      it "errors if no state is passed" do
        expect do
          expect(instance).to transition_on(:charge)
        end.to raise_error(/must use :to to provide a target state/)
      end
      it "can audit" do
        expect do
          expect(instance).to transition_on(:charge).to("foo").audit
        end.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          /SequelStateMachine::SpecModels::ChargeAuditLog/,
        )
      end
      it "can be used for models with multiple statre machines" do
        instance = SequelStateMachine::SpecModels::MultiMachine.create
        expect do
          expect(instance).to transition_on(:gom1state2).to("m1state3")
        end.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          "expected that event gom1state2 would transition to m1state3 but is m1state2",
        )
      end
      it "errors if event does not exist on any state machine" do
        instance = SequelStateMachine::SpecModels::MultiMachine.create
        instance.define_singleton_method(:foo) { true }
        expect do
          expect(instance).to transition_on(:foo).to("m1state3")
        end.to raise_error(
          ArgumentError,
          /has no state machine for event foo/,
        )
      end
    end
    describe "not_transition_on" do
      let(:instance) { SequelStateMachine::SpecModels::Charge.create }

      it "succeeds if no transition" do
        expect(instance).to not_transition_on(:charge)
      end
      it "can use args" do
        expect(instance).to receive(:charge).with(1)
        expect(instance).to not_transition_on(:charge).with(1)
      end
      it "errors if transition happens" do
        expect do
          expect(instance).to not_transition_on(:finalize)
        end.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          "expected that event finalize would not transition, but did and is now open",
        )
      end
      it "can be used for models with multiple state machines" do
        instance = SequelStateMachine::SpecModels::MultiMachine.create
        expect do
          expect(instance).to not_transition_on(:gom1state2)
        end.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          "expected that event gom1state2 would not transition, but did and is now m1state2",
        )
      end
      it "errors if the event is not found on a model" do
        instance = SequelStateMachine::SpecModels::MultiMachine.create
        instance.define_singleton_method(:foo) { true }
        expect do
          expect(instance).to not_transition_on(:foo)
        end.to raise_error(
          ArgumentError,
          /has no state machine for event foo/,
        )
      end
    end
  end

  def droptz(t)
    return Time.new(t.year, t.month, t.day, t.hour, t.min, t.sec, nil)
  end
end
