defmodule Aikido.TeamOperationTimeoutTest do
  use AikidoTest.Case, async: false

  alias Aikido.TeamMemberAdmissionTest.{Domain, DelayedWorker, UnboundedCoordinator, Coordinator}

  @moduletag aikido_instance: Aikido.TeamMemberAdmissionTest.Instance,
             aikido_scope_adapter: Aikido.TeamMemberAdmissionTest.Authority

  setup do
    clock = start_supervised!({Aikido.AttemptTimingTest.Manual, self()})
    instance = __MODULE__.Timed

    durable =
      Keyword.put(durable_options(), :scope_adapter, Aikido.TeamMemberAdmissionTest.Authority)

    start_supervised!(
      {Aikido, name: instance, durable: durable, timing: {Aikido.AttemptTimingTest.Manual, clock}}
    )

    actor = %{id: Ash.UUIDv7.generate(), allowed: true, coordinator?: true}

    options = [
      scope: %{actor: actor, tenant: "operation-timeout"},
      context: %{aikido_runtime_options: [instance: instance, timeout: :infinity]}
    ]

    {:ok, clock: clock, actor: actor, options: options}
  end

  test "native reducers omit topology deadlines only for the explicit opt-out" do
    for {resource, timeout} <- [{UnboundedCoordinator, :infinity}, {Coordinator, 5_000}],
        action <- [:start, :reconcile_inherited] do
      assert Aikido.Agent.Info.team_config(resource).timeout == timeout
      state = Ash.create!(Aikido.Team.Slice, %{})

      input =
        Ash.ActionInput.for_action(Aikido.Team.Slice, action, %{state: state},
          context: %{
            aikido: %{
              agent_module: resource,
              agent_pid: self(),
              signal: %Aikido.Signal{
                id: "deadline-test",
                type: "aikido.ash.team.start",
                data: %{}
              }
            }
          }
        )

      assert {:ok, result} = Ash.run_action(input)

      timers =
        for %Aikido.Directives.Schedule{message: %{type: "aikido.ash.team.timeout"}} = timer <-
              result.directives,
            do: timer

      if timeout == :infinity,
        do: assert(timers == []),
        else: assert([%{delay_ms: 5_000}] = timers)
    end
  end

  test "fresh activation accepts an explicit caller budget and no independent timer", ctx do
    Process.register(self(), Aikido.TeamMemberAdmissionTest.Observer)

    task =
      Task.async(fn ->
        Domain.unbounded_start(
          %{actor_id: ctx.actor.id, topology: %{delayed: %{resource: DelayedWorker}}},
          ctx.options
        )
      end)

    assert_receive {:member_start_held, child}, 5_000
    on_exit(fn -> send(child, :release_member_start) end)
    :ok = Aikido.AttemptTimingTest.Manual.advance(ctx.clock, 20_001)
    send(child, :release_member_start)
    assert {:ok, root} = Task.await(task, 5_000)
    assert team(root).members.delayed == child

    root_pid = root.pid

    refute_receive {:armed, ^root_pid, {:scheduled_signal, %{type: "aikido.ash.team.timeout"}},
                    _},
                   0
  end

  test "a lazy assignment survives delayed activation and keeps its authored task budget", ctx do
    root = start(ctx)

    Domain.unbounded_add_member!(
      root,
      %{member: :delayed, resource: DelayedWorker, activation: :lazy},
      ctx.options
    )

    Process.register(self(), Aikido.TeamMemberAdmissionTest.Observer)

    Domain.unbounded_assign_task!(
      root,
      %{
        member: :delayed,
        task_id: "delayed-task",
        type: "test.member.work",
        payload: %{result: "finished"},
        timeout_ms: 60_000
      },
      ctx.options
    )

    assert_receive {:member_start_held, child}, 5_000
    on_exit(fn -> send(child, :release_member_start) end)
    assert Map.has_key?(team(root).pending_tasks, "delayed-task")
    :ok = Aikido.AttemptTimingTest.Manual.advance(ctx.clock, 20_001)
    assert team(root).operation.status == :running
    send(child, :release_member_start)

    assert %{status: :completed, result: "finished"} =
             await_state_value(
               root.pid,
               fn runtime ->
                 case runtime.agent.state.team.tasks["delayed-task"] do
                   %{status: :completed} = task -> task
                   _ -> nil
                 end
               end,
               timeout: 5_000
             )

    assert_receive {:armed, _, {:scheduled_signal, %{type: "aikido.ash.team.task.timeout"}},
                    80_001},
                   5_000
  end

  test "finite topology timeout still fails and cleans up a late activation", ctx do
    root = Domain.coordinator_start!(%{actor_id: ctx.actor.id, topology: %{}}, ctx.options)
    Process.register(self(), Aikido.TeamMemberAdmissionTest.Observer)

    task =
      Task.async(fn ->
        Domain.coordinator_add_member(
          root,
          %{member: :delayed, resource: DelayedWorker},
          ctx.options
        )
      end)

    assert_receive {:member_start_held, child}, 5_000
    on_exit(fn -> send(child, :release_member_start) end)
    monitor = Process.monitor(child)

    assert_receive {:armed, _, {:scheduled_signal, %{type: "aikido.ash.team.timeout"}}, 5_000},
                   5_000

    :ok = Aikido.AttemptTimingTest.Manual.advance(ctx.clock, 5_001)
    assert {:error, _} = Task.await(task, 5_000)
    assert team(root).operation.status == :failed
    send(child, :release_member_start)
    assert_receive {:DOWN, ^monitor, :process, ^child, _}, 5_000
    refute Map.has_key?(team(root).members, :delayed)
  end

  test "lazy activation deadline is distinct from the already-running task budget", ctx do
    root = Domain.activation_bounded_start!(%{actor_id: ctx.actor.id}, ctx.options)

    Domain.activation_bounded_add_member!(
      root,
      %{member: :running, resource: Aikido.TeamMemberAdmissionTest.Worker},
      ctx.options
    )

    Domain.activation_bounded_add_member!(
      root,
      %{member: :delayed, resource: DelayedWorker, activation: :lazy},
      ctx.options
    )

    Domain.activation_bounded_assign_task!(
      root,
      %{
        member: :running,
        task_id: "running-control",
        type: "test.member.work",
        payload: %{result: "control-result", complete?: false},
        timeout_ms: 60_000
      },
      ctx.options
    )

    root_pid = root.pid

    assert_receive {:armed, ^root_pid,
                    {:scheduled_signal,
                     %{type: "aikido.ash.team.task.timeout", data: %{timeout_ms: 60_000}}},
                    60_000},
                   5_000

    Process.register(self(), Aikido.TeamMemberAdmissionTest.Observer)

    Domain.activation_bounded_assign_task!(
      root,
      %{
        member: :delayed,
        task_id: "lazy-assignment",
        type: "test.member.work",
        payload: %{result: "not-dispatched"},
        timeout_ms: 60_000
      },
      ctx.options
    )

    assert_receive {:member_start_held, child}, 5_000
    on_exit(fn -> send(child, :release_member_start) end)
    child_monitor = Process.monitor(child)
    operation_id = team(root).operation.id
    assert team(root).pending_tasks["lazy-assignment"].timeout_ms == 60_000

    assert_receive {:armed, ^root_pid,
                    {:scheduled_signal,
                     %{
                       type: "aikido.ash.team.timeout",
                       data: %{operation_id: ^operation_id, timeout_ms: 20_000}
                     }}, 20_000},
                   5_000

    :ok = Aikido.AttemptTimingTest.Manual.advance(ctx.clock, 20_001)

    failed =
      await_state_value(
        root.pid,
        fn runtime ->
          case runtime.agent.state.team.tasks["lazy-assignment"] do
            %{status: :failed} = task -> task
            _ -> nil
          end
        end,
        timeout: 5_000
      )

    assert %Aikido.Team.Errors.DeadlineExceeded{
             stage: :member_activation,
             timeout_ms: 20_000,
             operation_id: ^operation_id,
             task_id: "lazy-assignment",
             member: :delayed,
             attempt: nil
           } = failed.result

    assert failed.attempt == nil
    assert team(root).tasks["running-control"].status == :dispatched
    public = AshLua.Error.to_error(failed.result)
    assert public.code == "team_deadline_exceeded"
    assert public.vars.stage == :member_activation
    assert public.vars.timeout_ms == 20_000
    assert public.vars.task_id == "lazy-assignment"
    delivery = Aikido.Team.TaskDelivery.conversation_message_for_task_result(failed)
    assert delivery.data.text =~ AshAi.ToToolError.to_tool_error(failed.result)
    assert delivery.data.metadata.task.result == failed.result
    refute delivery.data.text =~ "workflow budget"
    send(child, :release_member_start)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, _}, 5_000
    running = team(root).members.running
    assert Process.alive?(running)
    Domain.worker_finish!(running, %{}, ctx.options)

    completed =
      await_state_value(
        root.pid,
        fn runtime ->
          case runtime.agent.state.team.tasks["running-control"] do
            %{status: :completed} = task -> task
            _ -> nil
          end
        end,
        timeout: 5_000
      )

    assert completed.result == "control-result"
    :ok = Aikido.AttemptTimingTest.Manual.advance(ctx.clock, 60_001)
    assert team(root).tasks["running-control"] == completed
  end

  test "parent stop cancels an unbounded pending activation", ctx do
    root = start(ctx)

    Domain.unbounded_add_member!(
      root,
      %{member: :delayed, resource: DelayedWorker, activation: :lazy},
      ctx.options
    )

    Process.register(self(), Aikido.TeamMemberAdmissionTest.Observer)

    Domain.unbounded_assign_task!(
      root,
      %{
        member: :delayed,
        task_id: "cancelled-task",
        type: "test.member.work",
        payload: %{result: "must-not-run"},
        timeout_ms: 60_000
      },
      ctx.options
    )

    assert_receive {:member_start_held, child}, 5_000
    on_exit(fn -> send(child, :release_member_start) end)
    root_monitor = Process.monitor(root.pid)
    child_monitor = Process.monitor(child)
    assert %{status: :stopped} = Domain.unbounded_stop!(root, ctx.options)
    assert_receive {:DOWN, ^root_monitor, :process, _, _}, 5_000
    send(child, :release_member_start)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, _}, 5_000
  end

  test "a finite caller wait can expire without imposing a topology deadline", ctx do
    root = start(ctx)
    Process.register(self(), Aikido.TeamMemberAdmissionTest.Observer)

    options =
      Keyword.update!(ctx.options, :context, fn context ->
        Map.update!(context, :aikido_runtime_options, &Keyword.put(&1, :timeout, 100))
      end)

    task =
      Task.async(fn ->
        Domain.unbounded_add_member(root, %{member: :delayed, resource: DelayedWorker}, options)
      end)

    assert_receive {:member_start_held, child}, 5_000
    on_exit(fn -> send(child, :release_member_start) end)
    assert {:error, error} = Task.await(task, 5_000)
    assert Exception.message(error) =~ "Waiting for the team operation"
    assert team(root).operation.status == :running
    send(child, :release_member_start)

    assert child ==
             await_state_value(
               root.pid,
               &Map.get(&1.agent.state.team.members, :delayed),
               timeout: 5_000
             )
  end

  test "permanent teams restore with an infinity topology configuration", ctx do
    root = start(ctx)
    Domain.unbounded_stop!(root, ctx.options)
    restored = Domain.unbounded_start!(%{id: root.id, actor_id: ctx.actor.id}, ctx.options)
    assert team(restored).operation.status == :completed
  end

  defp start(ctx), do: Domain.unbounded_start!(%{actor_id: ctx.actor.id}, ctx.options)

  defp team(root) do
    assert {:ok, team} = Aikido.AgentServer.state(root.pid, &{:ok, &1.agent.state.team})
    team
  end
end
