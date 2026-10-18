defmodule AikidoTest.AgentServer.StopChildTest do
  use AikidoTest.Case, async: false

  alias Aikido.AgentServer

  defmodule ParentAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name "stop_child_parent_agent"
    end
  end

  defmodule ChildAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name "stop_child_child_agent"
    end
  end

  test "stop_child/3 stops an adopted child with an atom tag", %{aikido: aikido} do
    {:ok, parent_pid} =
      AgentServer.start(agent_module: ParentAgent, id: unique_id("parent"), aikido: aikido)

    {:ok, child_pid} =
      AgentServer.start(agent_module: ChildAgent, id: unique_id("child"), aikido: aikido)

    assert {:ok, ^child_pid} = AgentServer.adopt_child(parent_pid, child_pid, :worker)
    assert :ok = AgentServer.stop_child(parent_pid, :worker)

    eventually(fn -> not Process.alive?(child_pid) end)
    await_state_value(parent_pid, fn s -> if map_size(s.children) == 0, do: true end)
  end

  test "stop_child/3 stops an adopted child with a string tag", %{aikido: aikido} do
    {:ok, parent_pid} =
      AgentServer.start(agent_module: ParentAgent, id: unique_id("parent"), aikido: aikido)

    {:ok, child_pid} =
      AgentServer.start(agent_module: ChildAgent, id: unique_id("child"), aikido: aikido)

    assert {:ok, ^child_pid} = AgentServer.adopt_child(parent_pid, child_pid, "worker")
    assert :ok = AgentServer.stop_child(parent_pid, "worker")

    eventually(fn -> not Process.alive?(child_pid) end)
    await_state_value(parent_pid, fn s -> if map_size(s.children) == 0, do: true end)
  end
end
