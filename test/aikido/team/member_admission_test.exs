defmodule Aikido.TeamMemberAdmissionTest do
  use AikidoTest.Case, async: false
  alias Aikido.TeamMemberAdmissionTest.{Domain, Worker}

  setup do
    options =
      Keyword.put(durable_options(), :scope_adapter, Aikido.TeamMemberAdmissionTest.Authority)

    start_supervised!({Aikido, name: Aikido.Default, durable: options})
    {:ok, owner: actor(true), alpha: actor(), bravo: actor()}
  end

  test "coordination exposes only the requester's tasks and explicitly public metadata", ctx do
    root = start_team(ctx)

    alpha_task =
      assign(root, :bravo, :alpha, ctx.alpha, %{result: "alpha-result"}, %{
        required_todo: "check-result",
        public: %{label: "authored-public"},
        secret: "private-metadata"
      })

    bravo_task = assign(root, :alpha, :bravo, ctx.bravo, %{result: "bravo-result"})
    complete(root, alpha_task)
    complete(root, bravo_task)
    pending = assign(root, :bravo, :alpha, ctx.alpha, %{result: "later", complete?: false})
    assert {:ok, view} = read(root, :alpha, ctx.alpha)
    assert view.coordinator.id == root.id

    assert Map.keys(Map.from_struct(view)) |> Enum.sort() == [
             :coordinator,
             :members,
             :requester,
             :tasks
           ]

    assert Enum.sort(Enum.map(view.tasks, & &1.id)) == Enum.sort([alpha_task, pending])
    task = Enum.find(view.tasks, &(&1.id == alpha_task))
    assert task.result == "alpha-result"
    assert task.metadata == %{required_todo: "check-result", public: %{label: "authored-public"}}
    assert Enum.find(view.members, &(&1.name == :bravo)).busy?

    assert Enum.all?(
             view.members,
             &(Map.keys(Map.from_struct(&1)) |> Enum.sort() == [:busy?, :name, :running?])
           )

    refute inspect(view) =~ "private-metadata"
    refute inspect(view) =~ "coordinator-secret"
    refute inspect(view) =~ "worker-secret"
    refute inspect(view) =~ "bravo-result"

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.coordinator_inspect(root, scope: scope(ctx.alpha))

    bravo = state(root.pid).team.members.bravo
    Domain.worker_finish!(bravo, %{}, scope: scope(ctx.bravo))
    complete(root, pending)
  end

  test "a real lazy activation appears as a requester-filtered pending task before dispatch",
       ctx do
    root = start_team(ctx)
    delayed_actor = actor()

    Domain.coordinator_add_member!(
      root,
      %{
        member: :delayed,
        resource: Aikido.TeamMemberAdmissionTest.DelayedWorker,
        activation: :lazy,
        initial_state: %{actor_id: delayed_actor.id}
      },
      scope: scope(ctx.owner)
    )

    Process.register(self(), Aikido.TeamMemberAdmissionTest.Observer)

    id =
      assign(root, :delayed, :alpha, ctx.alpha, %{
        result: "lazy-result",
        private_payload: "not-public"
      })

    assert_receive {:member_start_held, delayed}, 5_000
    on_exit(fn -> send(delayed, :release_member_start) end)
    assert Map.has_key?(state(root.pid).team.pending_tasks, id)
    assert {:ok, view} = read(root, :alpha, ctx.alpha)
    assert [%{id: ^id, status: :pending, member: :delayed}] = view.tasks
    refute Enum.find(view.members, &(&1.name == :delayed)).running?
    refute inspect(view) =~ "not-public"
    assert {:ok, sibling_view} = read(root, :bravo, ctx.bravo)
    assert sibling_view.tasks == []
    send(delayed, :release_member_start)
    complete(root, id)
    assert {:ok, completed_view} = read(root, :alpha, ctx.alpha)
    assert [%{id: ^id, status: :completed, result: "lazy-result"}] = completed_view.tasks
    assert own(delayed).seen_actor == delayed_actor.id
  end

  test "coordinator nil and self claims require its principal and retained nil tasks are not rewritten",
       ctx do
    root = start_team(ctx)
    old_id = assign(root, :alpha, nil, ctx.owner, %{result: "legacy-coordinator-result"})
    explicit_id = assign(root, :bravo, :self, ctx.owner, %{result: "explicit-self"})
    complete(root, old_id)
    complete(root, explicit_id)
    assert state(root.pid).team.tasks[old_id].requester == nil
    assert {:ok, view} = read(root, :self, ctx.owner)
    assert Enum.sort(Enum.map(view.tasks, & &1.id)) == Enum.sort([old_id, explicit_id])
    assert Enum.all?(view.tasks, &(&1.requester == :self))

    for requester <- [nil, :self] do
      assert {:error, %Ash.Error.Forbidden{}} = assignment(root, :bravo, requester, ctx.alpha)
    end

    assert {:error, %Ash.Error.Forbidden{}} = read(root, :self, ctx.alpha)
    old_workers = Map.values(state(root.pid).team.members)
    Domain.coordinator_stop!(root, scope: scope(ctx.owner))
    Enum.each(old_workers, &AikidoTest.LifecycleWait.await_down(&1, 5_000))

    restored =
      Domain.coordinator_start!(%{id: root.id, actor_id: ctx.owner.id}, scope: scope(ctx.owner))

    assert {:ok, restored_view} = read(restored, :self, ctx.owner)
    assert Enum.any?(restored_view.tasks, &(&1.id == old_id && &1.requester == :self))
    assert state(restored.pid).team.tasks[old_id].requester == nil
  end

  test "native assignment admission binds requester, notification and sibling target", ctx do
    root = start_team(ctx)

    for {member, requester, notify} <- [
          {:alpha, :bravo, :bravo},
          {:bravo, :alpha, :bravo},
          {:alpha, :alpha, :alpha},
          {:absent, :alpha, :alpha}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               assignment(root, member, requester, ctx.alpha, notify: notify)
    end

    assert {:error, %Ash.Error.Forbidden{}} = read(root, :bravo, ctx.alpha)
    assert {:error, %Ash.Error.Forbidden{}} = read(root, :alpha, %{ctx.alpha | allowed: false})
    assert state(root.pid).team.tasks == %{}
    id = assign(root, :bravo, :alpha, ctx.alpha, %{result: "accepted"})
    complete(root, id)
    assert own(state(root.pid).team.members.bravo).seen_actor == ctx.bravo.id
  end

  test "a stopped member and a same-name replacement with a different principal revoke the old claim",
       ctx do
    root = start_team(ctx)
    original = state(root.pid).team.members.alpha
    Domain.coordinator_stop_member!(root, %{member: :alpha}, scope: scope(ctx.owner))
    assert {:error, %Ash.Error.Forbidden{}} = read(root, :alpha, ctx.alpha)
    assert {:error, %Ash.Error.Forbidden{}} = assignment(root, :bravo, :alpha, ctx.alpha)
    Domain.coordinator_remove_member!(root, %{member: :alpha}, scope: scope(ctx.owner))
    replacement_actor = actor()

    Domain.coordinator_add_member!(
      root,
      %{
        member: :alpha,
        resource: Worker,
        initial_state: %{actor_id: replacement_actor.id}
      },
      scope: scope(ctx.owner)
    )

    replacement = state(root.pid).team.members.alpha
    assert replacement != original
    assert {:error, %Ash.Error.Forbidden{}} = read(root, :alpha, ctx.alpha)
    assert {:ok, _} = read(root, :alpha, replacement_actor)

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.coordinator_team_coordination(root, %{requester: :alpha},
               scope:
                 Map.put(scope(ctx.alpha), :context, %{
                   aikido_sender: %{pid: replacement, actor: replacement_actor}
                 })
             )
  end

  test "a member's logical owner may be another member while the coordinator proof remains authoritative",
       ctx do
    root = start_team(ctx, logical_owner?: true)
    members = state(root.pid).team.members

    assert {:ok, parent} =
             Aikido.AgentServer.state(members.bravo, &{:ok, Aikido.Ownership.parent(&1)})

    assert parent.pid == members.alpha
    assert parent.meta.team_pid == root.pid
    assert {:ok, _} = read(root, :bravo, ctx.bravo)
    id = assign(root, :alpha, :bravo, ctx.bravo, %{result: "logical-owner"})
    complete(root, id)
  end

  test "members deliberately sharing an immutable principal may act on behalf of either member",
       ctx do
    root = start_team(%{ctx | bravo: ctx.alpha})
    assert {:ok, view} = read(root, :bravo, ctx.alpha)
    assert view.requester == :bravo
    id = assign(root, :alpha, :bravo, ctx.alpha, %{result: "shared-principal"})
    complete(root, id)
  end

  test "malformed coordinator boundary metadata cannot match a real child's proof", ctx do
    root = start_team(ctx)

    assert {:ok, context} =
             Aikido.AgentServer.state(root.pid, fn runtime ->
               {:ok, Aikido.Team.MemberIdentity.coordinator_context(runtime, root.pid)}
             end)

    assert {:ok, true} =
             Aikido.Team.MemberIdentity.matches?(context, :alpha, scope(ctx.alpha), 100)

    # This unit boundary check changes only supplied metadata; the real agents and state stay untouched.
    for {key, value} <- [
          partition: "wrong-partition",
          aikido: Aikido.WrongRuntimeInstance,
          agent_module: Worker,
          agent_pid: self(),
          agent_id: "wrong-id"
        ] do
      assert {:ok, false} =
               Aikido.Team.MemberIdentity.matches?(
                 Map.put(context, key, value),
                 :alpha,
                 scope(ctx.alpha),
                 100
               )
    end

    assert {:ok, _} = read(root, :alpha, ctx.alpha)
  end

  test "a busy actual child fails closed with a typed runtime error and succeeds after release",
       ctx do
    root = start_team(ctx)
    alpha = state(root.pid).team.members.alpha
    Process.register(self(), Aikido.TeamMemberAdmissionTest.Observer)
    on_exit(fn -> send(alpha, :release_member) end)
    task = Task.async(fn -> Domain.worker_hold(alpha, %{}, scope: scope(ctx.alpha)) end)
    assert_receive {:member_held, ^alpha}, 5_000
    assert {:error, error} = read(root, :alpha, ctx.alpha)
    assert runtime_unavailable?(error), inspect(error)
    assert Process.alive?(alpha)
    send(alpha, :release_member)
    assert {:ok, _} = Task.await(task, 5_000)
    assert {:ok, _} = read(root, :alpha, ctx.alpha)
  end

  defp start_team(ctx, options \\ []) do
    bravo = %{resource: Worker, initial_state: %{actor_id: ctx.bravo.id}}
    bravo = if options[:logical_owner?], do: Map.put(bravo, :owner, :alpha), else: bravo

    Domain.coordinator_start!(
      %{
        id: Ash.UUIDv7.generate(),
        actor_id: ctx.owner.id,
        topology: %{
          alpha: %{resource: Worker, initial_state: %{actor_id: ctx.alpha.id}},
          bravo: bravo
        }
      },
      scope: scope(ctx.owner)
    )
  end

  defp actor(coordinator? \\ false),
    do: %{id: Ash.UUIDv7.generate(), allowed: true, coordinator?: coordinator?}

  defp scope(actor), do: %{actor: actor, tenant: "member-admission"}

  defp read(root, requester, actor),
    do: Domain.coordinator_team_coordination(root, %{requester: requester}, scope: scope(actor))

  defp assignment(root, member, requester, actor, options \\ []) do
    Domain.coordinator_assign_task(
      root,
      %{
        task_id: Ash.UUIDv7.generate(),
        member: member,
        requester: requester,
        notify: Keyword.get(options, :notify, requester),
        type: "test.member.work",
        payload: %{result: "denied"}
      },
      scope: scope(actor)
    )
  end

  defp assign(root, member, requester, actor, payload, metadata \\ %{}) do
    id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Domain.coordinator_assign_task(
               root,
               %{
                 task_id: id,
                 member: member,
                 requester: requester,
                 notify: requester,
                 type: "test.member.work",
                 payload: payload,
                 metadata: metadata
               },
               scope: scope(actor)
             )

    id
  end

  defp complete(root, id) do
    await_state_value(root.pid, fn runtime ->
      case runtime.agent.state.team.tasks[id] do
        %{status: :completed} = task -> task
        _ -> nil
      end
    end)
  end

  defp state(pid) do
    assert {:ok, attributes} =
             Aikido.AgentServer.state(pid, &{:ok, Aikido.Agent.resource_attributes(&1.agent)})

    attributes
  end

  defp own(pid), do: state(pid)
  defp runtime_unavailable?(%Aikido.Agent.Errors.RuntimeUnavailable{}), do: true
  defp runtime_unavailable?(%{errors: errors}), do: Enum.any?(errors, &runtime_unavailable?/1)
  defp runtime_unavailable?(_), do: false
end
