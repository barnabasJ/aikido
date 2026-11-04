defmodule Aikido.AncestorLossTest do
  use AikidoTest.Case, async: true
  @moduletag aikido_instance: Aikido.AncestorLossTest.Instance
  alias Aikido.AncestorLossTest.{Domain, Worker}

  test "a monitored grandchild exit settles without cleanup acknowledgement after its ancestor dies" do
    team = Domain.team_start!(%{id: unique_id("ancestor-loss"), topology: topology()})
    original = Domain.team_inspect!(team).team.members
    child_monitor = Process.monitor(original.child)
    grandchild_monitor = Process.monitor(original.grandchild)

    assert {:ok, subscription} =
             Aikido.AgentServer.subscribe(
               team.pid,
               "**",
               fn runtime ->
                 state = runtime.agent.state.team

                 replaced? =
                   Enum.all?(original, fn {name, old} ->
                     is_pid(state.members[name]) and state.members[name] != old
                   end)

                 if state.operation.status == :completed and replaced?,
                   do: {:ok, state},
                   else: :skip
               end,
               once: true
             )

    suspend(team.pid)
    suspend(original.grandchild)
    Process.exit(original.lead, :kill)
    assert_receive {:DOWN, ^child_monitor, :process, _, _}, 5_000
    :ok = :sys.resume(team.pid)

    captured =
      await_state_value(team.pid, fn runtime ->
        operation = runtime.agent.state.team.operation

        if (operation.status == :running and operation.awaiting == {:stop, :grandchild} and
              operation[:stop]) && operation.stop.monitor_ref,
           do: operation.stop
      end)

    assert captured.orphaned?
    refute captured.prepared?
    assert captured.exit == nil

    :ok = :sys.resume(original.grandchild)
    assert_receive {:DOWN, ^grandchild_monitor, :process, _, _}, 5_000
    assert_receive {:aikido_subscription, ^subscription, %{result: {:ok, recovered}}}, 5_000
    assert :grandchild in recovered.operation.observed_absent

    assert {:ok, %{pid: parent}} =
             Aikido.AgentServer.state(
               recovered.members.grandchild,
               &{:ok, Aikido.Ownership.parent(&1)}
             )

    assert parent == recovered.members.child
  end

  test "only a missing declared ownership ancestor permits observed absence" do
    {:ok, topology} = Aikido.Team.Topology.build(topology(), Aikido.AncestorLossTest.Instance)

    complete =
      Ash.create!(Aikido.Team.Slice, %{
        topology: topology,
        members: %{lead: self(), child: self(), grandchild: self()}
      })

    refute Aikido.Team.MemberStop.missing_owner_ancestor?(complete, :grandchild)

    assert Aikido.Team.MemberStop.missing_owner_ancestor?(
             Ash.create!(Aikido.Team.Slice, %{
               topology: topology,
               members: %{child: self(), grandchild: self()}
             }),
             :grandchild
           )

    refute Aikido.Team.MemberStop.missing_owner_ancestor?(complete, :lead)
    refute Aikido.Team.MemberStop.missing_owner_ancestor?(complete, :undeclared)

    for nodes <- [
          %{grandchild: %{owner: :child}, child: %{owner: :grandchild}},
          %{grandchild: %{owner: :missing}},
          %{grandchild: %{owner: :child}, child: :malformed},
          %{grandchild: %{owner: :child}, child: %{resource: Worker}}
        ] do
      malformed =
        Ash.create!(Aikido.Team.Slice, %{
          topology: Aikido.Team.Topology.new!(nodes: nodes),
          members: %{grandchild: self()}
        })

      refute Aikido.Team.MemberStop.missing_owner_ancestor?(malformed, :grandchild)
    end
  end

  defp topology do
    %{
      lead: %{resource: Worker},
      child: %{resource: Worker, owner: :lead},
      grandchild: %{resource: Worker, owner: :child}
    }
  end

  defp suspend(pid) do
    :ok = :sys.suspend(pid)

    on_exit(fn ->
      try do
        :sys.resume(pid, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)
  end
end
