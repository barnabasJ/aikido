defmodule Aikido.Team.MemberStopScopeTest do
  use AikidoTest.Case, async: false
  alias Aikido.InheritedConfigurationTest.{Access, Domain, Worker}
  alias AikidoTest.LifecycleWait

  setup do
    options =
      Keyword.put(durable_options(), :scope_adapter, Aikido.InheritedConfigurationTest.Authority)

    start_supervised!({Aikido, name: Aikido.Default, durable: options})
    {:ok, parent_actor: actor(), child_actor: actor()}
  end

  test "tracked member stop prepares cleanup with the child's identity and observes its exit",
       ctx do
    root = start_team(ctx)
    child = snapshot(root.pid).team.members.worker
    stop = observe_cleanup(child)
    monitor = Process.monitor(child)

    Domain.root_stop_member!(root, %{member: :worker}, scope: scope(ctx.parent_actor))

    assert_receive {:aikido_subscription, ^stop, %{result: {:ok, {actor, "member-stop", nil}}}}
    assert actor.id == ctx.child_actor.id
    assert_receive {:DOWN, ^monitor, :process, ^child, _}
    assert snapshot(root.pid).team.operation.status == :completed
    refute Map.has_key?(snapshot(root.pid).team.members, :worker)
  end

  test "receiver cleanup denial fails the operation and leaves the member alive", ctx do
    root = start_team(ctx)
    child = snapshot(root.pid).team.members.worker
    access = Ash.get!(Access, ctx.child_actor.id, authorize?: false)
    access = Ash.update!(access, %{active?: false}, authorize?: false)

    assert {:error, _} =
             Domain.root_stop_member(root, %{member: :worker}, scope: scope(ctx.parent_actor))

    assert Process.alive?(child)
    assert snapshot(root.pid).team.members.worker == child
    assert snapshot(root.pid).team.operation.status == :failed
    assert %Ash.Error.Forbidden{} = snapshot(root.pid).team.operation.error

    Ash.update!(access, %{active?: true}, authorize?: false)
    Domain.root_stop_member!(root, %{member: :worker}, scope: scope(ctx.parent_actor))
    LifecycleWait.await_down(child)
  end

  test "public child stop retains the actual caller's authorization", ctx do
    root = start_team(ctx)
    child = snapshot(root.pid).team.members.worker
    reference = %{id: "#{root.id}/worker", pid: child, resource: Worker}

    assert {:error, _} = Domain.worker_stop(reference, scope: scope(ctx.parent_actor))
    assert Process.alive?(child)
    Domain.worker_stop!(reference, scope: scope(ctx.child_actor))
    LifecycleWait.await_down(child)
  end

  test "removing an owner waits for the verified exit of its differently owned descendant", ctx do
    root =
      Domain.root_start!(
        %{
          id: ctx.parent_actor.id,
          actor_id: ctx.parent_actor.id,
          topology: %{
            manager: %{resource: Worker},
            worker: %{
              resource: Worker,
              owner: :manager,
              initial_state: %{actor_id: ctx.child_actor.id}
            }
          }
        },
        scope: scope(ctx.parent_actor)
      )

    members = snapshot(root.pid).team.members
    stop = observe_cleanup(members.worker)

    Domain.root_remove_member!(root, %{member: :manager, cascade?: true},
      scope: scope(ctx.parent_actor)
    )

    assert_receive {:aikido_subscription, ^stop, %{result: {:ok, {actor, "member-stop", nil}}}}
    assert actor.id == ctx.child_actor.id
    LifecycleWait.await_down(members.worker)
    LifecycleWait.await_down(members.manager)
    assert snapshot(root.pid).team.operation.status == :completed
    assert snapshot(root.pid).team.members == %{}
  end

  test "parent shutdown already uses the child's receiving scope", ctx do
    root = start_team(ctx)
    child = snapshot(root.pid).team.members.worker
    stop = observe_cleanup(child)

    Domain.root_stop!(root, scope: scope(ctx.parent_actor))

    assert_receive {:aikido_subscription, ^stop, %{result: {:ok, {actor, "member-stop", nil}}}},
                   5_000

    assert actor.id == ctx.child_actor.id
    LifecycleWait.await_down(child)
  end

  test "typed acknowledgement and exit payloads cannot finish a real pending cleanup", ctx do
    root = start_team(ctx)
    child = snapshot(root.pid).team.members.worker
    Process.register(self(), Aikido.InheritedConfigurationTest.MemberStopObserver)
    on_exit(fn -> send(child, :continue_member_stop) end)

    task =
      Task.async(fn ->
        Domain.root_stop_member(root, %{member: :worker}, scope: scope(ctx.parent_actor))
      end)

    assert_receive {:member_stop_waiting, ^child}, 5_000
    operation = snapshot(root.pid).team.operation
    assert operation.awaiting == {:stop, :worker}

    forged =
      Aikido.Team.Signals.Stopped.new!(
        %{member: :worker, pid: child, operation_id: operation.id, result: :prepared},
        scope: scope(ctx.parent_actor)
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Aikido.AgentServer.call(root.pid, forged, &{:ok, &1.agent})

    exit_signal =
      Aikido.Ownership.Signals.ChildExit.new!(
        %{tag: :worker, pid: child, child_id: "#{root.id}/worker", reason: :normal},
        scope: scope(ctx.parent_actor)
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Aikido.AgentServer.call(root.pid, exit_signal, &{:ok, &1.agent})

    assert snapshot(root.pid).team.operation.status == :running
    assert Process.alive?(child)
    send(child, :continue_member_stop)
    assert {:ok, _} = Task.await(task, 5_000)
    assert snapshot(root.pid).team.operation.status == :completed
  end

  test "a real crash while cleanup is pending fails instead of acknowledging a stop", ctx do
    root = start_team(ctx)
    child = snapshot(root.pid).team.members.worker
    Process.register(self(), Aikido.InheritedConfigurationTest.MemberStopObserver)
    on_exit(fn -> send(child, :continue_member_stop) end)

    task =
      Task.async(fn ->
        Domain.root_stop_member(root, %{member: :worker}, scope: scope(ctx.parent_actor))
      end)

    assert_receive {:member_stop_waiting, ^child}, 5_000
    Process.exit(child, :kill)

    assert {:error, _} = Task.await(task, 5_000)
    assert snapshot(root.pid).team.operation.status == :failed

    assert {:member_stop_failed, :worker, {:unexpected_exit, :killed}} =
             snapshot(root.pid).team.operation.error
  end

  test "a late activation is cleaned under its receiving identity without being installed", ctx do
    root =
      Domain.root_start!(%{id: ctx.parent_actor.id, actor_id: ctx.parent_actor.id},
        scope: scope(ctx.parent_actor)
      )

    Process.register(self(), Aikido.InheritedConfigurationTest.MemberStartObserver)

    task =
      Task.async(fn ->
        Domain.root_add_member(
          root,
          %{
            member: :late,
            resource: Aikido.InheritedConfigurationTest.DelayedBranch,
            initial_state: %{actor_id: ctx.child_actor.id}
          },
          scope: scope(ctx.parent_actor)
        )
      end)

    assert_receive {:member_start_waiting, child}, 5_000
    on_exit(fn -> send(child, :continue_member_start) end)

    {:ok, cleanup} =
      Aikido.AgentServer.subscribe(
        root.pid,
        "aikido.ash.team.cleanup",
        fn _, event -> {:ok, event.error} end,
        once: true
      )

    operation = snapshot(root.pid).team.operation

    timeout =
      Aikido.Team.Signals.Timeout.new!(%{operation_id: operation.id},
        scope: scope(ctx.parent_actor)
      )

    assert {:ok, _} = Aikido.AgentServer.call(root.pid, timeout, &{:ok, &1.agent})
    assert {:error, _} = Task.await(task, 5_000)
    send(child, :continue_member_start)

    assert_receive {:aikido_subscription, ^cleanup, %{result: {:ok, nil}}}, 5_000
    LifecycleWait.await_down(child)
    refute Map.has_key?(snapshot(root.pid).team.members, :late)
  end

  test "an unauthorized stale Started cannot turn a real pending activation into privileged cleanup",
       ctx do
    root =
      Domain.root_start!(%{id: ctx.parent_actor.id, actor_id: ctx.parent_actor.id},
        scope: scope(ctx.parent_actor)
      )

    Process.register(self(), Aikido.InheritedConfigurationTest.MemberStartObserver)

    task =
      Task.async(fn ->
        Domain.root_add_member(
          root,
          %{
            member: :late,
            resource: Aikido.InheritedConfigurationTest.DelayedBranch,
            initial_state: %{actor_id: ctx.child_actor.id}
          },
          scope: scope(ctx.parent_actor)
        )
      end)

    assert_receive {:member_start_waiting, child}, 5_000
    on_exit(fn -> send(child, :continue_member_start) end)
    {:ok, partition} = Aikido.AgentServer.state(root.pid, &{:ok, &1.partition})

    reference =
      Aikido.Agent.Reference.new!(
        id: "#{root.id}/late",
        resource: Aikido.InheritedConfigurationTest.DelayedBranch,
        aikido: Aikido.Default,
        partition: partition
      )

    forged =
      Aikido.Team.Signals.Started.new!(
        %{member: :late, operation_id: "fabricated", result: child, reference: reference},
        scope: scope(%{id: "unauthorized", allowed: true})
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Aikido.AgentServer.call(root.pid, forged, &{:ok, &1.agent})

    refute Map.has_key?(snapshot(root.pid).team.failures, :late)
    assert snapshot(root.pid).team.operation.status == :running
    send(child, :continue_member_start)
    assert {:ok, _} = Task.await(task, 5_000)
    assert snapshot(root.pid).team.members.late == child
    assert Process.alive?(child)
  end

  test "owner crash recovery observes retained descendant absence before rebuilding its subtree",
       ctx do
    root =
      Domain.root_start!(
        %{
          id: ctx.parent_actor.id,
          actor_id: ctx.parent_actor.id,
          topology: %{
            manager: %{resource: Worker},
            worker: %{
              resource: Worker,
              owner: :manager,
              initial_state: %{actor_id: ctx.child_actor.id}
            }
          }
        },
        scope: scope(ctx.parent_actor)
      )

    old = snapshot(root.pid).team.members

    {:ok, recovered} =
      Aikido.AgentServer.subscribe(
        root.pid,
        "aikido.ash.team.**",
        fn runtime ->
          team = runtime.agent.state.team

          if team.operation.status == :completed && is_pid(team.members[:manager]) &&
               is_pid(team.members[:worker]) && team.members.manager != old.manager &&
               team.members.worker != old.worker, do: {:ok, team.members}, else: :skip
        end,
        once: true
      )

    Process.exit(old.manager, :kill)

    assert_receive {:aikido_subscription, ^recovered, %{result: {:ok, members}}}, 10_000
    assert Process.alive?(members.manager)
    assert Process.alive?(members.worker)
    LifecycleWait.await_down(old.worker)
  end

  test "an early unmatched raw monitor tuple cannot remove a live stop target", ctx do
    root = start_team(ctx)
    child = snapshot(root.pid).team.members.worker
    Process.register(self(), Aikido.InheritedConfigurationTest.MemberStopObserver)
    parent = self()

    observer =
      Task.async(fn ->
        Process.register(self(), Aikido.InheritedConfigurationTest.StopPlanningObserver)
        send(parent, :stop_plan_observer_ready)

        receive do
          {:member_stop_planned, _, _, _, _} = event -> event
        end
      end)

    assert_receive :stop_plan_observer_ready

    on_exit(fn ->
      send(root.pid, :continue_stop_plan)
      send(child, :continue_member_stop)
    end)

    task =
      Task.async(fn ->
        Domain.root_stop_member(root, %{member: :worker}, scope: scope(ctx.parent_actor))
      end)

    assert {:member_stop_planned, root_pid, id, :worker, ^child} = Task.await(observer, 5_000)
    assert root_pid == root.pid
    send(root.pid, {{:aikido_team_stop, id, :worker}, make_ref(), :process, child, :normal})
    send(root.pid, :continue_stop_plan)
    assert_receive {:member_stop_waiting, ^child}, 5_000
    assert snapshot(root.pid).team.members.worker == child
    assert snapshot(root.pid).team.operation.status == :running
    send(child, :continue_member_stop)
    assert {:ok, _} = Task.await(task, 5_000)
    assert snapshot(root.pid).team.operation.status == :completed
  end

  test "a raw typed stopped acknowledgement cannot claim receiving cleanup", ctx do
    root = start_team(ctx)
    child = snapshot(root.pid).team.members.worker

    forged =
      Aikido.Team.Signals.Stopped.new!(
        %{member: :worker, pid: child, operation_id: "fabricated", result: :prepared},
        scope: scope(ctx.parent_actor)
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Aikido.AgentServer.call(root.pid, forged, &{:ok, &1.agent})

    assert snapshot(root.pid).team.members.worker == child
    assert Process.alive?(child)
  end

  defp start_team(ctx) do
    Domain.root_start!(
      %{
        id: ctx.parent_actor.id,
        actor_id: ctx.parent_actor.id,
        topology: %{worker: %{resource: Worker, initial_state: %{actor_id: ctx.child_actor.id}}}
      },
      scope: scope(ctx.parent_actor)
    )
  end

  defp observe_cleanup(pid) do
    {:ok, ref} =
      Aikido.AgentServer.subscribe(
        pid,
        "aikido.agent.lifecycle.stopping",
        fn _, event ->
          {:ok, {event.signal.scope[:actor], event.signal.scope[:tenant], event.error}}
        end,
        once: true
      )

    ref
  end

  defp actor do
    actor = %{id: Ash.UUIDv7.generate(), allowed: true}
    Ash.create!(Access, %{id: actor.id}, authorize?: false)
    actor
  end

  defp scope(actor), do: %{actor: actor, tenant: "member-stop"}

  defp snapshot(pid) do
    assert {:ok, agent} = Aikido.AgentServer.state(pid, &{:ok, &1.agent})
    Aikido.Agent.resource_attributes(agent)
  end
end
