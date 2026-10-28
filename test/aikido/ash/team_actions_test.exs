defmodule AikidoTest.AshTeamActionsTest do
  use ExUnit.Case, async: true

  alias AikidoTest.AshFixtures.DynamicTeam

  test "unknown task members produce native argument errors with recovery instructions" do
    state = Ash.create!(Aikido.Team.Slice, %{})
    input = team_input(:assign_task, state, %{member: :missing, task_id: "task-1"})
    assert {:error, %{errors: [error]}} = Ash.run_action(input)
    assert %Ash.Error.Action.InvalidArgument{field: :member} = error
    assert AshAi.ToToolError.to_tool_error(error) =~ "Inspect the roster"
    assert AshLua.Error.to_error(error).code == "invalid_argument"
  end

  test "a failed member activation retains a typed error instead of an opaque tuple" do
    state = Ash.create!(Aikido.Team.Slice, %{})
    input = team_input(:ensure_member, state, %{member: :missing})
    assert {:ok, result} = Ash.run_action(input)
    assert result.changes.operation.status == :failed
    error = result.changes.operation.error
    assert %Ash.Error.Action.InvalidArgument{field: :member} = error
    assert AshLua.Error.to_error(error).message =~ "before activating"
  end

  test "an unknown template reports configured alternatives through the failed operation" do
    state = Ash.create!(Aikido.Team.Slice, %{})
    input = team_input(:add_member, state, %{member: :new_worker, template: :missing})
    assert {:ok, result} = Ash.run_action(input)
    error = result.changes.operation.error
    assert %Ash.Error.Action.InvalidArgument{field: :template} = error
    assert AshLua.Error.to_error(error).message =~ "configured templates"
    assert AshAi.ToToolError.to_tool_error(error) =~ ":counter"
  end

  test "a duplicate task explains how to reuse the existing assignment" do
    state = Ash.create!(Aikido.Team.Slice, %{tasks: %{"task-1" => %{member: :worker}}})
    input = team_input(:assign_task, state, %{member: :worker, task_id: "task-1"})
    assert {:error, %{errors: [error]}} = Ash.run_action(input)
    assert %Ash.Error.Action.InvalidArgument{field: :task_id} = error
    assert AshLua.Error.to_error(error).message =~ "background the existing task"
  end

  defp team_input(action, state, arguments) do
    Ash.ActionInput.for_action(Aikido.Team.Slice, action, Map.put(arguments, :state, state),
      context: %{
        aikido: %{
          agent_module: DynamicTeam,
          agent_pid: self(),
          signal: %Aikido.Signal{id: "team-error", type: "team.command", data: %{}}
        }
      }
    )
  end

  test "the team slice owns removal of live bindings from every snapshot" do
    slice =
      Ash.create!(Aikido.Team.Slice, %{
        members: %{worker: self()},
        incarnations: %{worker: "live-incarnation"},
        operation: %{status: :running},
        queued_operations: [%Aikido.Signal{type: "aikido.ash.team.reconcile", data: %{}}]
      })

    for snapshot <- [Aikido.Team.Slice.externalize(slice), Aikido.Team.Slice.reinstate(slice)] do
      assert snapshot.members == %{}
      assert snapshot.incarnations == %{}
      assert snapshot.queued_operations == []
      assert snapshot.operation.status == :idle
    end

    assert slice.members.worker == self()
    assert slice.operation.status == :running
  end

  test "team routes generate typed reducers and expose only command routes" do
    routes = Spark.Dsl.Extension.get_entities(Aikido.Team.Slice, [:slice])
    assert length(routes) == 22

    for route <- routes do
      assert Aikido.Signal.Routes.valid_definition?(route.signal_module)
      assert Aikido.Signal.Routes.valid_implementation?(route.implementation)
      {Aikido.Team.Slice, action_name} = route.action
      action = Ash.Resource.Info.action(Aikido.Team.Slice, action_name)
      state = Enum.find(action.arguments, &(&1.name == :state))
      assert state.type == Ash.Type.Struct
      assert state.constraints[:instance_of] == Aikido.Team.Slice

      assert Enum.map(action.arguments, & &1.name) -- [:state] ==
               Enum.map(Aikido.Signal.Info.schema(route.signal_module), & &1.name)
    end

    public = for route <- routes, route.public?, do: route.name
    assert :configure_topology in public
    assert :assign_task in public
    refute :task_completed in public
    refute :child_exit in public
  end

  test "replaying a queued command preserves its exact scope instead of inheriting the preceding caller" do
    queued =
      Aikido.Signal.new!("aikido.ash.team.add_member", %{member: "next"})
      |> Aikido.Signal.put_ctx(%{actor: nil, context: %{request: "next"}})

    previous =
      Aikido.Signal.new!("aikido.ash.team.operation.completed", %{})
      |> Aikido.Signal.put_ctx(%{actor: %{id: "other"}, tenant: "other-tenant"})

    state = %{queued_operations: [queued]}

    assert {%{queued_operations: []}, [effect]} =
             Aikido.Team.TopologyOperation.release_queued_operations(state, %{agent_pid: self()})

    assert :ok = Aikido.Directives.Emit.exec(effect, previous, %{})
    assert_received {:signal, replayed}
    assert replayed == queued
    refute Map.has_key?(Aikido.Signal.ctx(replayed), :tenant)
  end

  test "the native action owns its operation independently of the signal envelope type" do
    recipient = self()
    state = Ash.create!(Aikido.Team.Slice, %{members: %{worker: recipient}})

    input =
      Ash.ActionInput.for_action(
        Aikido.Team.Slice,
        :send,
        %{state: state, member: :worker, type: "worker.notice", payload: %{value: 7}},
        context: %{
          aikido: %{
            agent_module: DynamicTeam,
            signal: %Aikido.Signal{
              id: "native-send",
              type: "unrelated.envelope",
              data: %{},
              source: "/test"
            }
          }
        }
      )

    assert {:ok,
            %Aikido.Types.ActionResult{
              changes: nil,
              directives: [
                %Aikido.Directives.Emit{
                  target: ^recipient,
                  signal: %Aikido.Signal{type: "worker.notice", data: %{value: 7}}
                }
              ]
            }} = Ash.run_action(input)

    refute_received {:signal, _}
  end
end
