defmodule AikidoTest.TestAgents.Minimal do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "minimal_agent"
  end
end

defmodule AikidoTest.TestAgents.Counter do
  @moduledoc """
  Standard test agent with counter and messages state.

  Routes:
    - "increment" -> IncrementAction
    - "decrement" -> DecrementAction
    - "record" -> RecordAction
    - "slow" -> SlowAction
    - "fail" -> FailingAction
  """
  use Aikido.Agent

  agent do
    name "counter_agent"
    description "Test agent with counter and message tracking"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
      attribute :messages, {:array, :term}, default: []
    end

    route "increment", {AikidoTest.TestActions, :increment}
    route "decrement", {AikidoTest.TestActions, :decrement}
    route "record", {AikidoTest.TestActions, :record}
    route "slow", {AikidoTest.TestActions, :slow}
    route "fail", {AikidoTest.TestActions, :failing}
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
      attribute :counter, :integer, default: 0
      attribute :status, :atom, default: :idle
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
      attribute :status, :atom, allow_nil?: false, default: :idle
      attribute :count, :integer, allow_nil?: false, default: 0
    end
  end
end

defmodule AikidoTest.TestAgents.TestSliceWithRoutes do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "test_routes_slice"

    schema do
      attribute :value, :term, allow_nil?: true
    end

    route "post", {AikidoTest.TestActions, :plugin_test_action}
    route "list", {AikidoTest.TestActions, :plugin_test_action}
  end
end

defmodule AikidoTest.TestAgents.TestSliceWithPriority do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "priority_slice"

    schema do
      attribute :value, :term, allow_nil?: true
    end

    route "action", {AikidoTest.TestActions, :plugin_test_action}, priority: 5
  end
end

defmodule AikidoTest.TestAgents.AgentWithSliceRoutes do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "agent_with_slice_routes"
    slice :test_routes, AikidoTest.TestAgents.TestSliceWithRoutes
  end
end

defmodule AikidoTest.TestAgents do
  @moduledoc """
  Shared test agents for Aikido test suite.
  """
  Code.ensure_compiled!(AikidoTest.TestActions)
  Code.ensure_compiled!(AikidoTest.TestActions)
end
