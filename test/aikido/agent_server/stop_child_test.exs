defmodule AikidoTest.AgentServer.StopChildTest.ParentAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "stop_child_parent_agent"
  end
end

defmodule AikidoTest.AgentServer.StopChildTest.ChildAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "stop_child_child_agent"
  end
end

defmodule AikidoTest.AgentServer.StopChildTest do
  use AikidoTest.Case, async: false

  test("stop_child/3 stops an adopted child with an atom tag", %{aikido: aikido}) do
    {:ok, parent_pid} =
      Aikido.start_agent(aikido, AikidoTest.AgentServer.StopChildTest.ParentAgent,
        id: unique_id("parent")
      )

    {:ok, child_pid} =
      Aikido.start_agent(aikido, AikidoTest.AgentServer.StopChildTest.ChildAgent,
        id: unique_id("child")
      )

    assert {:ok, ^child_pid} = Aikido.AgentServer.adopt_child(parent_pid, child_pid, :worker)
    assert :ok = Aikido.AgentServer.stop_child(parent_pid, :worker)
    AikidoTest.LifecycleWait.await_down(child_pid)

    await_state_value(parent_pid, fn s ->
      if map_size(s.children) == 0 do
        true
      end
    end)
  end

  test("stop_child/3 stops an adopted child with a string tag", %{aikido: aikido}) do
    {:ok, parent_pid} =
      Aikido.start_agent(aikido, AikidoTest.AgentServer.StopChildTest.ParentAgent,
        id: unique_id("parent")
      )

    {:ok, child_pid} =
      Aikido.start_agent(aikido, AikidoTest.AgentServer.StopChildTest.ChildAgent,
        id: unique_id("child")
      )

    assert {:ok, ^child_pid} = Aikido.AgentServer.adopt_child(parent_pid, child_pid, "worker")
    assert :ok = Aikido.AgentServer.stop_child(parent_pid, "worker")
    AikidoTest.LifecycleWait.await_down(child_pid)

    await_state_value(parent_pid, fn s ->
      if map_size(s.children) == 0 do
        true
      end
    end)
  end
end
