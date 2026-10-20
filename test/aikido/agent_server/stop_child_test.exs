defmodule AikidoTest.AgentServer.StopChildTest.RecordExit do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{exit_tags: input.arguments.state.exit_tags ++ [input.arguments.tag]}
    )
  end
end

defmodule AikidoTest.AgentServer.StopChildTest.ParentAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "stop_child_parent_agent"
    path :domain

    schema do
      attribute :exit_tags, {:array, :term}, default: []
    end

    route "aikido.agent.child.exit", :record_exit
  end

  actions do
    action :record_exit, Aikido.Types.ActionResult do
      argument :state, :term
      argument :tag, :term, allow_nil?: false
      run AikidoTest.AgentServer.StopChildTest.RecordExit
    end
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

  test "false child tags deliver exit events to reducers and subscribers", %{aikido: aikido} do
    {:ok, parent} =
      AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServer.StopChildTest.ParentAgent,
        id: unique_id("parent")
      )

    {:ok, child} =
      AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServer.StopChildTest.ChildAgent,
        id: unique_id("child")
      )

    assert {:ok, ^child} = Aikido.AgentServer.adopt_child(parent, child, false)
    monitor = Process.monitor(child)

    assert {:ok, {[false], %{}}} =
             Aikido.AgentServer.call_until(
               parent,
               fn -> Aikido.AgentServer.stop_child(parent, false) end,
               "aikido.agent.child.exit",
               &{:ok, {&1.agent.state.domain.exit_tags, &1.children}}
             )

    assert_receive {:DOWN, ^monitor, :process, ^child, _}

    send(parent, {:DOWN, make_ref(), :process, child, :normal})

    assert {:ok, [false]} =
             Aikido.AgentServer.state(parent, &{:ok, &1.agent.state.domain.exit_tags})
  end

  test("stop_child/3 stops an adopted child with an atom tag", %{aikido: aikido}) do
    {:ok, parent_pid} =
      AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServer.StopChildTest.ParentAgent,
        id: unique_id("parent")
      )

    {:ok, child_pid} =
      AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServer.StopChildTest.ChildAgent,
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
      AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServer.StopChildTest.ParentAgent,
        id: unique_id("parent")
      )

    {:ok, child_pid} =
      AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServer.StopChildTest.ChildAgent,
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
