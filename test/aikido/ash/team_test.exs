defmodule AikidoTest.AshTeamTest do
  use AikidoTest.Case, async: false
  alias AikidoTest.AshFixtures.{Counter, Domain, DynamicTeam}
  alias Aikido.Team.Topology

  setup do
    start_supervised!(
      {Aikido, name: AikidoTest.AshFixtures.Instance, durable: AikidoTest.Case.durable_options()}
    )

    :ok
  end

  test "team commands derive their public arguments from the owning reducer" do
    for name <- [:add_member, :send] do
      public = Ash.Resource.Info.action(DynamicTeam, name)
      reducer = Ash.Resource.Info.action(Aikido.Team.Slice, name)

      assert Enum.map(public.arguments, & &1.name) -- [:agent] ==
               Enum.map(reducer.arguments, & &1.name) -- [:state]
    end

    input =
      Ash.ActionInput.for_action(Aikido.Team.Slice, :add_member, %{
        state: Ash.create!(Aikido.Team.Slice, %{}),
        member: "worker",
        activation: "lazy"
      })

    assert input.valid?
    assert input.arguments.activation == :lazy
    assert input.arguments.initial_state == %{}
    assert input.arguments.depends_on == []

    assert {:error, %Ash.Error.Invalid{}} =
             Aikido.Team.Slice
             |> Ash.ActionInput.for_action(:add_member, %{
               state: Ash.create!(Aikido.Team.Slice, %{}),
               member: "worker",
               activation: :unknown
             })
             |> Ash.run_action()
  end

  test "send validates its native inputs before delivery and defaults its payload" do
    team = Domain.team_start!(%{id: "send-contract"})

    for arguments <- [
          %{type: "counter.increment"},
          %{member: :worker},
          %{member: :worker, type: "counter.increment", payload: 5},
          %{member: :worker, type: %{invalid: true}}
        ] do
      input = Ash.ActionInput.for_action(DynamicTeam, :send, Map.put(arguments, :agent, team))
      refute input.valid?
      assert {:error, %Ash.Error.Invalid{}} = Ash.run_action(input)
    end

    input =
      Ash.ActionInput.for_action(DynamicTeam, :send, %{
        agent: team,
        member: :worker,
        type: "counter.increment"
      })

    assert input.valid?
    assert input.arguments.payload == %{}

    cast =
      Ash.ActionInput.for_action(DynamicTeam, :send, %{
        agent: team,
        member: :worker,
        type: "counter.increment",
        payload: ~s({"amount": 2})
      })

    assert cast.valid?
    assert cast.arguments.payload == %{"amount" => 2}

    worker = Domain.team_inspect!(team).team.members.worker

    assert {:ok, ref} =
             Aikido.AgentServer.subscribe(
               worker,
               "counter.increment",
               &{:ok, &1.agent.state.state.count},
               once: true
             )

    assert {:ok, _} = Domain.team_send(team, %{member: :worker, type: "counter.increment"})
    assert_receive {:aikido_subscription, ^ref, %{result: {:ok, 3}}}

    assert {:error, %{errors: [%Ash.Error.Action.InvalidArgument{} = error]}} =
             Domain.team_send(team, %{member: :missing, type: "counter.increment"})

    assert AshAi.ToToolError.to_tool_error(error) =~ "ensure_member"
    assert AshLua.Error.to_error(error).code == "invalid_argument"
  end

  test "lifecycle commands return even when they complete immediately and release their subscriptions" do
    team = snapshot_result(Domain.dynamic_start!(%{id: "immediate"}))

    for _ <- 1..5 do
      completed = snapshot_result(Domain.dynamic_reconcile!(team))
      assert completed.team.operation.status == :completed
    end

    pid = AikidoTest.Case.agent_pid(AikidoTest.AshFixtures.Instance, team.id)
    assert {:ok, 0} = Aikido.AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)})
  end

  test "team children inherit synchronization policy unless their start config overrides it" do
    team =
      Domain.dynamic_start!(%{
        id: "sync-inheritance",
        sync: %{mode: :automatic, interval_ms: 777}
      })

    Domain.dynamic_add_member!(team, %{member: "inherited", template: :counter})

    Domain.dynamic_add_member!(team, %{
      member: "overridden",
      template: :counter,
      initial_state: %{sync: %{mode: :periodic, interval_ms: 2_000}}
    })

    current = Domain.dynamic_inspect!(team)
    inherited = :sys.get_state(current.team.members["inherited"])
    overridden = :sys.get_state(current.team.members["overridden"])
    assert inherited.auto_sync
    assert inherited.sync_every_ms == 777
    refute overridden.auto_sync
    assert overridden.sync_every_ms == 2_000
  end

  test "parallel topology commands queue until each member activation settles" do
    team = Domain.dynamic_start!(%{id: "parallel-workers"})
    observer = self()

    tasks =
      for name <- ["one", "two"] do
        Task.async(fn ->
          send(observer, {:ready_to_spawn, self()})

          receive do
            :spawn -> Domain.dynamic_add_member(team, %{member: name, template: :counter})
          end
        end)
      end

    for _ <- tasks do
      assert_receive {:ready_to_spawn, pid}
      send(pid, :spawn)
    end

    for task <- tasks, do: assert({:ok, _} = Task.await(task, 10_000))
    current = Domain.dynamic_inspect!(team)
    assert Map.keys(current.team.members) |> Enum.sort() == ["one", "two"]
    assert current.team.queued_operations == []
  end

  test "dynamic worker templates can add, stop, ensure, and remove string-named workers" do
    team = snapshot_result(Domain.dynamic_start!(%{id: "dynamic"}))
    assert team.team.members == %{}

    team =
      snapshot_result(
        Domain.dynamic_add_member!(team, %{
          member: "worker-1",
          template: :counter,
          initial_state: %{count: 8}
        })
      )

    state = team.team
    assert state.operation.status == :completed
    pid = state.members["worker-1"]
    assert {:ok, 8} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.state.count})

    stopped = snapshot_result(Domain.dynamic_stop_member!(team, %{member: "worker-1"}))
    state = stopped.team
    assert state.operation.status == :completed
    assert state.members == %{}
    assert Map.has_key?(state.topology.nodes, "worker-1")

    ensured = snapshot_result(Domain.dynamic_ensure_member!(team, %{member: "worker-1"}))
    state = ensured.team
    assert state.operation.status == :completed
    assert state.members["worker-1"] != pid
    removed = snapshot_result(Domain.dynamic_remove_member!(team, %{member: "worker-1"}))
    state = removed.team
    assert state.operation.status == :completed
    assert state.members == %{}
    assert state.topology.nodes == %{}
  end

  test "runtime topology startup respects dependencies and ownership" do
    team =
      snapshot_result(
        Domain.dynamic_start!(%{
          id: "graph",
          topology: %{
            "lead" => %{resource: Counter, activation: :lazy},
            "worker" => %{resource: Counter, owner: "lead", depends_on: ["lead"]}
          }
        })
      )

    state = team.team
    assert state.operation.status == :completed
    assert state.operation.started == ["lead", "worker"]

    assert {:ok, parent} =
             Aikido.AgentServer.state(
               state.members["worker"],
               &{:ok, Aikido.Ownership.parent(&1)}
             )

    assert parent.pid == state.members["lead"]
    assert parent.meta.team_id == "graph"
    assert parent.meta.team_resource == DynamicTeam

    assert parent.meta.team_pid ==
             AikidoTest.Case.agent_pid(AikidoTest.AshFixtures.Instance, "graph")

    removed = snapshot_result(Domain.dynamic_remove_member!(team, %{member: "lead"}))
    state = removed.team
    assert state.operation.status == :completed
    assert state.operation.stopped == ["worker", "lead"]
    assert state.topology.nodes == %{}
  end

  test "startup topology replaces DSL members and an empty graph stays empty" do
    team =
      snapshot_result(
        Domain.team_start!(%{
          id: "override",
          topology: %{"chosen" => %{resource: Counter, initial_state: %{count: 7}}}
        })
      )

    assert Map.keys(team.team.members) == ["chosen"]

    assert {:ok, 7} =
             Aikido.AgentServer.state(
               team.team.members["chosen"],
               &{:ok, &1.agent.state.state.count}
             )

    assert AikidoTest.Case.agent_pid(AikidoTest.AshFixtures.Instance, "override/worker") == nil

    empty = snapshot_result(Domain.team_start!(%{id: "empty", topology: %{}}))
    assert empty.team.members == %{}
    assert empty.team.topology.nodes == %{}
  end

  test "nested startup topologies reach child teams before start returns" do
    root =
      Domain.dynamic_start!(%{
        id: "nested-graph",
        topology: %{
          "squad" => %{
            resource: DynamicTeam,
            initial_state: %{
              topology: %{"inner" => %{resource: Counter, initial_state: %{count: 9}}}
            }
          }
        }
      })

    root = Domain.dynamic_inspect!(root)
    squad = Domain.dynamic_inspect!(root.team.members["squad"])
    assert squad.team.operation.status == :completed
    assert Map.keys(squad.team.members) == ["inner"]

    assert {:ok, 9} =
             Aikido.AgentServer.state(
               squad.team.members["inner"],
               &{:ok, &1.agent.state.state.count}
             )
  end

  test "invalid startup graphs fail before activating a process" do
    for {id, topology} <- [
          {"cycle",
           %{"a" => %{resource: Counter, owner: "b"}, "b" => %{resource: Counter, owner: "a"}}},
          {"missing", %{"a" => %{resource: Counter, depends_on: ["absent"]}}},
          {"limit", Map.new(1..6, &{to_string(&1), %{resource: Counter}})}
        ] do
      assert {:error, _} = Domain.dynamic_start(%{id: id, topology: topology})
      assert AikidoTest.Case.agent_pid(AikidoTest.AshFixtures.Instance, id) == nil
    end
  end

  test "lazy members and nested teams start without blocking directive execution" do
    team = snapshot_result(Domain.nested_start!(%{id: "nested"}))
    assert Map.keys(team.team.members) == [:subteam]
    subteam = team.team.members.subteam

    assert {:ok, 2} =
             Aikido.AgentServer.state(subteam, &{:ok, map_size(&1.agent.state.team.members)})

    ensured = snapshot_result(Domain.nested_ensure_member!(team, %{member: :lazy}))
    state = ensured.team
    assert state.operation.status == :completed
    assert is_pid(state.members.lazy)
    pids = [state.members.lazy, subteam]
    monitors = Enum.map(pids, &{&1, Process.monitor(&1)})
    assert {:ok, %{status: :stopped}} = Domain.nested_stop(team)
    for {pid, ref} <- monitors, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 2_000)
  end

  test "invalid mutations and capacity errors do not alter desired state" do
    team = snapshot_result(Domain.dynamic_start!(%{id: "limits"}))

    for name <- ["one", "two"] do
      added =
        snapshot_result(Domain.dynamic_add_member!(team, %{member: name, template: :counter}))

      assert added.team.operation.status == :completed
    end

    assert {:error, _} =
             snapshot_result(
               Domain.dynamic_add_member(team, %{member: "three", template: :counter})
             )

    assert {:error, _} =
             snapshot_result(
               Domain.dynamic_add_member(team, %{
                 member: "bad",
                 resource: Counter,
                 depends_on: ["missing"]
               })
             )

    assert {:error, _} =
             snapshot_result(
               Domain.dynamic_configure_topology(team, %{
                 topology: %{
                   "a" => %{resource: Counter, depends_on: ["b"]},
                   "b" => %{resource: Counter, depends_on: ["a"]}
                 }
               })
             )

    [read] = Enum.filter(Domain.dynamic_list!(), &(&1.id == team.id))
    assert map_size(read.team.topology.nodes) == 2
  end

  test "removing dependencies requires an explicit cascade" do
    team = snapshot_result(Domain.dynamic_start!(%{id: "dependency"}))

    started =
      snapshot_result(
        Domain.dynamic_configure_topology!(team, %{
          topology: %{
            "a" => %{resource: Counter},
            "b" => %{resource: Counter, depends_on: ["a"]}
          }
        })
      )

    assert started.team.operation.status == :completed
    assert {:error, _} = snapshot_result(Domain.dynamic_remove_member(team, %{member: "a"}))
    removed = snapshot_result(Domain.dynamic_remove_member!(team, %{member: "a", cascade?: true}))
    state = removed.team
    assert state.operation.status == :completed
    assert state.operation.stopped == ["b", "a"]
  end

  test "task completion is correlated to a member incarnation" do
    team = snapshot_result(Domain.dynamic_start!(%{id: "tasks"}))
    added = snapshot_result(Domain.dynamic_add_member!(team, %{member: "echo", template: :echo}))
    assert added.team.operation.status == :completed
    pid = AikidoTest.Case.agent_pid(AikidoTest.AshFixtures.Instance, team.id)

    {:ok, ref} =
      Aikido.AgentServer.subscribe(
        pid,
        "aikido.ash.team.task.completed",
        fn s -> {:ok, s.agent.state.team.tasks["task-1"]} end,
        once: true
      )

    assert {:ok, _} =
             snapshot_result(
               Domain.dynamic_assign_task(team, %{
                 member: "echo",
                 task_id: "task-1",
                 payload: %{text: "hello"}
               })
             )

    assert_receive {:aikido_subscription, ^ref,
                    %{result: {:ok, %{status: :completed, result: "HELLO"}}}},
                   2_000

    assert {:error, _} =
             snapshot_result(
               Domain.dynamic_assign_task(team, %{
                 member: "echo",
                 task_id: "task-1",
                 payload: %{text: "again"}
               })
             )
  end

  test "topology validation is pure and rejects missing resources" do
    assert {:error, _} =
             Topology.build(%{"missing" => %{resource: String}}, AikidoTest.AshFixtures.Instance)

    config = Aikido.Agent.Info.team_config(DynamicTeam)
    assert config.max_members == 5
    assert config.workers.counter.max_members == 2
  end

  test "an owner's crash reconciles its active descendants through lifecycle events" do
    team =
      Domain.dynamic_start!(%{
        topology: %{
          "lead" => %{resource: Counter},
          "child" => %{resource: Counter, owner: "lead"},
          "grandchild" => %{resource: Counter, owner: "child"}
        }
      })

    original = Domain.dynamic_inspect!(team).team.members

    {:ok, subscription} =
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
            do: {:ok, state.members},
            else: :skip
        end,
        once: true
      )

    Process.exit(original["lead"], :kill)
    assert_receive {:aikido_subscription, ^subscription, %{result: {:ok, replacements}}}, 5_000

    assert {:ok, %{pid: parent}} =
             Aikido.AgentServer.state(
               replacements["grandchild"],
               &{:ok, Aikido.Ownership.parent(&1)}
             )

    assert parent == replacements["child"]
  end

  # Commands return receipts; state assertions opt into a separate inspection.
  defp snapshot_result({:ok, %{resource: resource, id: id}}),
    do: resource |> Ash.ActionInput.for_action(:inspect, %{agent: id}) |> Ash.run_action()

  defp snapshot_result({:error, _} = error), do: error

  defp snapshot_result(%{resource: resource, id: id}),
    do: resource |> Ash.ActionInput.for_action(:inspect, %{agent: id}) |> Ash.run_action!()
end
