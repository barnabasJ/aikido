defmodule AikidoTest.TeamDelegationTest do
  use ExUnit.Case, async: true
  alias Aikido.Team.TaskDependencies

  test "foreground assignments reject direct and transitive circular waits" do
    state = %{tasks: %{"ab" => task(:a, :b), "bc" => task(:b, :c)}}

    assert {:error, error} =
             TaskDependencies.validate_assignment(state, %{
               requester: :c,
               member: :a,
               mode: :foreground
             })

    assert error.members == [:c, :a, :b, :c]
    assert Exception.message(error) =~ "c -> a -> b -> c"
    assert AshAi.ToToolError.to_tool_error(error) =~ "background mode"
    assert AshLua.Error.to_error(error).code == "delegation_cycle"

    assert {:error, _} =
             TaskDependencies.validate_assignment(state, %{
               requester: :a,
               member: :a,
               mode: :foreground
             })
  end

  test "background and settled tasks do not hold wait dependencies" do
    state = %{tasks: %{"ab" => task(:a, :b), "bc" => task(:b, :c)}}

    assert :ok =
             TaskDependencies.validate_assignment(state, %{
               requester: :c,
               member: :a,
               mode: :background
             })

    for changes <- [%{mode: :background}, %{status: :completed}, %{status: :failed}] do
      changed = update_in(state.tasks["ab"], &Map.merge(&1, changes))

      assert :ok =
               TaskDependencies.validate_assignment(changed, %{
                 requester: :c,
                 member: :a,
                 mode: :foreground
               })
    end
  end

  test "dependencies include assignments waiting for lazy activation" do
    state = %{tasks: %{}, pending_tasks: %{"ab" => Map.delete(task(:a, :b), :status)}}

    assert {:error, _} =
             TaskDependencies.validate_assignment(state, %{
               requester: :b,
               member: :a,
               mode: :foreground
             })
  end

  test "native assignment rejects a cycle before emitting work or changing the ledger" do
    state = Ash.create!(Aikido.Team.Slice, %{tasks: %{"ab" => task(:a, :b)}})

    input =
      Ash.ActionInput.for_action(
        Aikido.Team.Slice,
        :assign_task,
        %{state: state, requester: :b, member: :a, mode: :foreground},
        context: %{
          aikido: %{
            agent_module: AikidoTest.AshFixtures.DynamicTeam,
            signal: %Aikido.Signal{id: "cycle", type: "aikido.ash.team.assign_task", data: %{}}
          }
        }
      )

    assert {:error, error} = Ash.run_action(input)
    assert Exception.message(error) =~ "b -> a -> b"
    refute_received {:signal, _}
  end

  test "backgrounding removes only the wait and preserves task identity and result delivery" do
    original =
      task(:a, :b)
      |> Map.merge(%{id: "ab", notify: nil, metadata: %{deadline: 123}, attempt: "incarnation"})

    state = Ash.create!(Aikido.Team.Slice, %{tasks: %{"ab" => original}})
    assert {:ok, result} = background(state, "ab")
    task = result.state.tasks["ab"]
    assert task == %{original | mode: :background, notify: :a}
    assert result.directives == []

    assert :ok =
             TaskDependencies.validate_assignment(result.state, %{
               requester: :b,
               member: :a,
               mode: :foreground
             })

    assert {:ok, repeated} = background(result.state, "ab")
    assert repeated.state == result.state

    finished = put_in(state.tasks["ab"].status, :completed)
    assert {:ok, unchanged} = background(finished, "ab")
    fields = Enum.map(Ash.Resource.Info.attributes(Aikido.Team.Slice), & &1.name)
    assert Map.take(unchanged.state, fields) == Map.take(finished, fields)
    assert {:error, error} = background(state, "missing")
    assert Exception.message(error) =~ "Unknown delegated task missing"
  end

  test "a foreground assignment can be backgrounded while its worker is activating" do
    pending = Map.delete(task(:a, :b), :status)
    state = Ash.create!(Aikido.Team.Slice, %{tasks: %{}, pending_tasks: %{"ab" => pending}})
    assert {:ok, result} = background(state, "ab")
    assert result.state.pending_tasks["ab"].mode == :background
    assert result.state.pending_tasks["ab"].notify == :a
    assert result.state.tasks == %{}
  end

  test "a delayed activation replay cannot undo backgrounding or dispatch a second identity" do
    pending = %{member: :b, requester: :a, mode: :background, notify: :a}

    state =
      Ash.create!(Aikido.Team.Slice, %{
        tasks: %{},
        pending_tasks: %{"ab" => pending},
        members: %{b: self()},
        incarnations: %{b: "attempt"}
      })

    input =
      Ash.ActionInput.for_action(
        Aikido.Team.Slice,
        :assign_task,
        %{state: state, task_id: "ab", requester: :a, member: :b, mode: :foreground},
        context: %{
          aikido: %{
            agent_module: AikidoTest.AshFixtures.DynamicTeam,
            agent_pid: self(),
            signal: %Aikido.Signal{id: "replay", type: "aikido.ash.team.assign_task", data: %{}}
          }
        }
      )

    assert {:ok, result} = Ash.run_action(input)
    assert result.state.tasks["ab"].mode == :background
    assert result.state.tasks["ab"].notify == :a
    assert result.state.pending_tasks == %{}
    assert map_size(result.state.tasks) == 1
    refute_received {:signal, _}
  end

  defp task(requester, member),
    do: %{requester: requester, member: member, status: :dispatched, mode: :foreground}

  defp background(state, id) do
    Aikido.Team.Slice
    |> Ash.ActionInput.for_action(:background_task, %{state: state, task_id: id})
    |> Ash.run_action()
  end
end
