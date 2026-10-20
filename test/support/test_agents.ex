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
    - "increment" -> TestActions.increment
    - "decrement" -> TestActions.decrement
    - "record" -> TestActions.record
    - "slow" -> TestActions.slow
    - "fail" -> TestActions.failing
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
