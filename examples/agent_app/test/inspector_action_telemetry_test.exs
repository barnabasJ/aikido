defmodule AgentExamples.InspectorActionTelemetryTest do
  use ExUnit.Case, async: false
  alias AgentExamples.Agents
  alias Aikido.Inspector.History, as: Inspector

  test "native telemetry records every invoked handler in order, with timings and no inputs" do
    agent = Agents.counter_start!(%{})
    on_exit(fn -> Agents.counter_stop(agent) end)
    ref = observe(agent.pid, "counter.add")

    Agents.counter_add!(agent, %{amount: 7})
    assert_receive {:aikido_subscription, ^ref, %{result: {:ok, execution}}}, 5000
    assert execution.action_count == 2

    assert Enum.map(execution.actions, & &1.implementation) == [
             "AgentExamples.Counter.Actions.Increment",
             "AgentExamples.Counter.Actions.CountAll"
           ]

    for action <- execution.actions do
      assert action.resource == "AgentExamples.Counter"
      assert action.mount_paths == ["state"]
      assert is_number(action.duration_ms) && action.duration_ms >= 0
      refute Map.has_key?(action, :arguments)
    end

    # A later signal gets a fresh observation, rather than the preceding action list.
    ref = observe(agent.pid, "counter.notice")
    signal = Aikido.Signal.new!("counter.notice", %{})
    Aikido.AgentServer.cast(agent.pid, signal)
    assert_receive {:aikido_subscription, ^ref, %{result: {:ok, notice}}}, 5000
    assert notice.action_count == 1
    assert hd(notice.actions).implementation == "AgentExamples.Counter.Actions.CountAll"
  end

  test "mounted reducers resolve their implementation and configured path from DSL info" do
    agent = Agents.notebook_start!(%{})
    on_exit(fn -> Agents.notebook_stop(agent) end)
    ref = observe(agent.pid, "journal.append")
    Agents.notebook_append!(agent, %{text: "native slice"})

    assert_receive {:aikido_subscription, ^ref, %{result: {:ok, execution}}}, 5000
    assert [action] = execution.actions
    assert action.resource == "AgentExamples.Journal"
    assert action.implementation == "AgentExamples.Journal.Actions.AppendEntry"
    assert action.mount_paths == ["journal"]
  end

  test "returned business errors retain action timings alongside the signal error" do
    agent = Agents.checklist_start!(%{})
    on_exit(fn -> Agents.checklist_stop(agent) end)
    ref = observe(agent.pid, "checklist.complete")
    assert {:error, _} = Agents.checklist_complete(agent, %{item: "missing"})

    assert_receive {:aikido_subscription, ^ref, %{result: {:ok, execution}}}, 5000
    assert execution.error
    assert [action] = execution.actions
    assert action.implementation == "AgentExamples.Checklist.Actions.Complete"
    assert is_number(action.duration_ms)
    assert Process.alive?(agent.pid)
  end

  defp observe(pid, type) do
    {:ok, ref} =
      Aikido.AgentServer.subscribe(
        pid,
        type,
        fn runtime, event ->
          {:ok, Inspector.project_event(event, runtime.agent_module)}
        end,
        once: true
      )

    ref
  end
end
