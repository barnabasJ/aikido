defmodule AikidoTest.Ownership.ChildLifecycleTest do
  use AikidoTest.Case, async: true
  alias Aikido.Ownership.Slice
  alias Aikido.Ownership.Signals.{ChildStarted, ChildExit, ChildMonitored}
  alias AikidoTest.TestAgents.Basic

  setup context do
    owner = start_server(context, Basic, id: "owner")
    first = start_server(context, Basic, id: "owner/first")
    second = start_server(context, Basic, id: "owner/second")
    {:ok, slice} = Aikido.AgentServer.state(owner, &{:ok, &1.agent.state.ownership})
    {:ok, owner: owner, first: first, second: second, slice: slice}
  end

  test "an exit before monitor acknowledgement removes the child and releases the late monitor",
       context do
    ref = Process.monitor(context.first)
    on_exit(fn -> Process.demonitor(ref, [:flush]) end)
    started = transition(context, context.slice, :child_started, announcement(context.first))
    assert started.record.children.worker.ref == nil
    assert [%Aikido.Ownership.Directives.MonitorChild{pid: pid}] = started.directives
    assert pid == context.first

    exited =
      transition(
        context,
        started.record,
        :child_exit,
        ChildExit.new!(%{tag: :worker, pid: context.first, reason: :normal, monitor_ref: ref})
      )

    assert exited.record.children == %{}

    late =
      transition(
        context,
        exited.record,
        :child_monitored,
        ChildMonitored.new!(%{tag: :worker, pid: context.first, ref: ref})
      )

    assert late.record == exited.record
    assert [%Aikido.Directives.Demonitor{ref: ^ref}] = late.directives
  end

  test "a replaced child's exit cannot remove its replacement", context do
    ref = Process.monitor(context.first)
    on_exit(fn -> Process.demonitor(ref, [:flush]) end)
    first = transition(context, context.slice, :child_started, announcement(context.first))

    monitored =
      transition(
        context,
        first.record,
        :child_monitored,
        ChildMonitored.new!(%{tag: :worker, pid: context.first, ref: ref})
      )

    replacement =
      transition(context, monitored.record, :child_started, announcement(context.second))

    assert replacement.record.children.worker.pid == context.second

    assert [%Aikido.Directives.Demonitor{ref: ^ref}, %Aikido.Ownership.Directives.MonitorChild{}] =
             replacement.directives

    stale =
      transition(
        context,
        replacement.record,
        :child_exit,
        ChildExit.new!(%{tag: :worker, pid: context.first, reason: :killed, monitor_ref: ref})
      )

    assert stale.record == replacement.record
    assert stale.directives == []
    assert Slice.externalize(replacement.record).children == %{}
  end

  test "a repeated startup announcement preserves the current monitor", context do
    first = transition(context, context.slice, :child_started, announcement(context.first))
    repeated = transition(context, first.record, :child_started, announcement(context.first))
    assert repeated.record == first.record
    assert repeated.directives == []
  end

  defp announcement(pid) do
    ChildStarted.new!(%{
      parent_id: "owner",
      child_id: "owner/worker",
      child_module: Basic,
      tag: :worker,
      pid: pid,
      meta: %{}
    })
  end

  defp transition(context, slice, action, signal) do
    input =
      Ash.ActionInput.for_action(Slice, action, Map.put(signal.data, :state, slice),
        context: %{aikido: %{agent_id: "owner", agent_pid: context.owner, signal: signal}}
      )

    result = Ash.run_action!(input)
    assert result == Ash.run_action!(input)

    record =
      if result.changes in [nil, %{}],
        do: slice,
        else: Ash.update!(slice, result.changes, action: :update)

    %{record: record, directives: result.directives}
  end
end
