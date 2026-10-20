defmodule Aikido.Dsl.AgentTest.SimpleAgent do
  use Aikido.Agent

  agent do
    name "simple_agent"
    description "An agent with native typed state."
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

defmodule Aikido.Dsl.AgentTest do
  use ExUnit.Case, async: true

  test "the convenience host installs the native extension" do
    assert Aikido.Ash.Agent in Spark.extensions(Aikido.Dsl.AgentTest.SimpleAgent)

    assert Ash.Resource.Info.attribute(Aikido.Dsl.AgentTest.SimpleAgent, :counter).type ==
             Ash.Type.Integer

    assert Aikido.Ash.Agent.Info.slice_instances(Aikido.Dsl.AgentTest.SimpleAgent) == []
  end

  test "native initialization casts own state and applies resource defaults" do
    agent = Aikido.Dsl.AgentTest.SimpleAgent.initialize!()
    assert agent.agent_module == Aikido.Dsl.AgentTest.SimpleAgent
    assert agent.state.domain == %{counter: 0, status: :idle}
    agent = Aikido.Dsl.AgentTest.SimpleAgent.initialize!(%{state: %{counter: "5"}})
    assert agent.state.domain == %{counter: 5, status: :idle}
  end

  test "invalid typed initial state returns native Ash errors" do
    assert {:error, %Ash.Error.Invalid{}} =
             Aikido.Dsl.AgentTest.SimpleAgent.initialize(%{state: %{counter: "invalid"}})
  end
end
