defmodule AikidoTest.TestAgents.Minimal do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "minimal_agent"
  end
end

defmodule AikidoTest.TestAgents.Counter do
  @moduledoc "Counter agent with typed commands and a retained message history."
  use Aikido.Agent

  agent do
    name "counter_agent"
    description "Test agent with counter and message tracking"
    path :domain

    schema do
      attribute :counter, :integer do
        description "Counter used to observe routed state transitions."
        default 0
      end

      attribute :messages, {:array, :term} do
        description "Messages retained by the agent in delivery order."
        default []
      end
    end

    route AikidoTest.TestSignals.Increment, AikidoTest.TestActions.Actions.IncrementCounter,
      public?: false,
      name: :increment

    route AikidoTest.TestSignals.Decrement, AikidoTest.TestActions.Actions.DecrementCounter,
      public?: false,
      name: :decrement

    route AikidoTest.TestSignals.Record, AikidoTest.TestActions.Actions.RecordMessage,
      public?: false,
      name: :record

    route AikidoTest.TestSignals.Fail, AikidoTest.TestActions.Actions.Fail,
      public?: false,
      name: :fail
  end
end

defmodule AikidoTest.TestAgents.Basic do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "basic_agent"
    description "A basic test agent"
    path :domain

    schema do
      attribute :counter, :integer do
        description "Counter used to observe routed state transitions."
        default 0
      end

      attribute :status, :atom do
        description "Current lifecycle or processing status of the fixture."
        default :idle
      end
    end
  end
end

defmodule AikidoTest.TestAgents.AshSchema do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "ash_schema_agent"
    path :domain

    schema do
      attribute :status, :atom do
        description "Current lifecycle or processing status of the fixture."
        allow_nil? false
        default :idle
      end

      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        allow_nil? false
        default 0
      end
    end
  end
end

defmodule AikidoTest.TestAgents.Arithmetic do
  @moduledoc "A calculator that stores a value or resolves an optional numeric input."
  use Aikido.Agent

  agent do
    name "arithmetic"
    path :domain

    schema do
      attribute :value, :integer do
        description "Last stored or calculated numeric value."
      end

      attribute :result, :term do
        description "Resolved optional input or its no-input explanation."
      end
    end

    route AikidoTest.TestSignals.OptionalInput,
          AikidoTest.TestActions.Actions.ResolveOptionalValue,
          public?: false,
          name: :optional_input

    route AikidoTest.TestSignals.StoreValue,
          AikidoTest.TestActions.Actions.StoreValue, public?: false, name: :basic_action

    route AikidoTest.TestSignals.AddValue,
          AikidoTest.TestActions.Actions.AddValue, public?: false, name: :add

    route AikidoTest.TestSignals.Fail, AikidoTest.TestActions.Actions.Fail,
      public?: false,
      name: :failing
  end
end

defmodule AikidoTest.TestAgents.EventSource do
  @moduledoc "An event source that records emissions and queues a follow-up timer."
  use Aikido.Agent

  agent do
    name "event_source"
    path :domain

    schema do
      attribute :emitted, :boolean do
        description "Whether an event has been emitted."
        default false
      end

      attribute :triggered, :boolean do
        description "Whether an emission and a follow-up timer have been requested."
        default false
      end
    end

    route AikidoTest.TestSignals.Emit,
          AikidoTest.TestActions.Actions.EmitTestSignal, public?: false, name: :emit_action

    route AikidoTest.TestSignals.EmitAndSchedule,
          AikidoTest.TestActions.Actions.EmitAndSchedule,
          public?: false,
          name: :multi_effect_action
  end
end

defmodule AikidoTest.TestAgents.AuditTrail do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "audit_trail"

    schema do
      attribute :last_event, :atom do
        description "Most recent coordinated update recorded by the audit trail."
        default :none
      end
    end

    route AikidoTest.TestSignals.UpdateAudit,
          AikidoTest.TestActions.Actions.RecordAuditEvent,
          public?: false,
          name: :record_event
  end
end

defmodule AikidoTest.TestAgents.AuditedWorkflow do
  @moduledoc "A workflow and its audit trail that react independently to the same signal."
  use Aikido.Agent

  agent do
    name "audited_workflow"
    path :domain

    schema do
      attribute :primary, :string do
        description "Most recent workflow result."
      end
    end

    slice :audit, AikidoTest.TestAgents.AuditTrail

    route AikidoTest.TestSignals.UpdateAudit,
          AikidoTest.TestActions.Actions.RecordWorkflowResult,
          public?: false,
          name: :record_result,
          priority: 10
  end
end
