defmodule Aikido.Dsl.AgentOptionalPathTest.EmptyAgent do
  use Aikido.Agent

  agent do
    name "empty_agent"
  end
end

defmodule Aikido.Dsl.AgentOptionalPathTest.CompositionAgent do
  use Aikido.Agent

  agent do
    name "composition_agent"
    slice :memory, Aikido.Memory.Slice
  end
end

defmodule Aikido.Dsl.AgentOptionalPathTest do
  use ExUnit.Case, async: true

  test "an empty agent uses the standard own state path and no implicit slices" do
    agent = Aikido.Dsl.AgentOptionalPathTest.EmptyAgent.initialize!()
    assert agent.state == %{state: %{}}
    assert Aikido.Agent.Info.slices(agent.agent_module) == []
  end

  test "composition requires only an explicit mount, without an own schema" do
    agent = Aikido.Dsl.AgentOptionalPathTest.CompositionAgent.initialize!()
    assert %Aikido.Memory.Slice{} = agent.state.memory
    assert agent.state.state == %{}
    assert Aikido.Agent.Info.slice_paths(agent.agent_module) == [:memory]
  end
end
