defmodule AgentExamples.Quicksort.RetryTest do
  use ExUnit.Case, async: true
  alias AgentExamples.Quicksort
  alias AgentExamples.Quicksort.Actions.{RetryChild, ScheduleChildRetry, StartChild}

  test "a transient activation failure preserves the partition and retries with backoff" do
    agent = agent()

    {scheduled, directives} =
      apply_action(agent, ScheduleChildRetry, %{tag: "L", child_id: "root/L", reason: :timeout})

    assert own(scheduled).partitions == own(agent).partitions
    assert own(scheduled).child_attempts == %{"L" => 1}
    assert [%Aikido.Directives.Schedule{delay_ms: 500, message: retry}] = directives
    {retried, directives} = apply_action(scheduled, RetryChild, retry.data)
    assert [%Aikido.Directives.SpawnAgent{tag: "L"}] = directives
    assert retried == scheduled
  end

  test "late readiness supersedes a scheduled retry and stale generations do nothing" do
    agent = agent(%{"L" => 2})
    {stale, directives} = apply_action(agent, RetryChild, %{tag: "L", attempt: 1})
    assert directives == []
    assert stale == agent

    {ready, _directives} =
      apply_action(agent, StartChild, %{
        tag: "L",
        pid: self(),
        child_id: "root/L",
        parent_id: "root",
        child_module: Quicksort
      })

    {_retry, directives} = apply_action(ready, RetryChild, %{tag: "L", attempt: 2})
    assert directives == []

    {_ignored, directives} =
      apply_action(ready, ScheduleChildRetry, %{tag: "L", child_id: "root/L", reason: :timeout})

    assert directives == []
  end

  test "exhaustion terminates the partition and cancellation prevents retry" do
    agent = agent(%{"L" => 8})

    {failed, _directives} =
      apply_action(agent, ScheduleChildRetry, %{tag: "L", child_id: "root/L", reason: :timeout})

    assert own(failed).status == :failed
    assert own(failed).error.reason == :timeout
    {_ignored, directives} = apply_action(failed, RetryChild, %{tag: "L", attempt: 8})
    assert directives == []
  end

  defp apply_action(agent, implementation, arguments) do
    [action] =
      Enum.filter(Ash.Resource.Info.actions(Quicksort), fn
        %{type: :action, run: {^implementation, _}} -> true
        _ -> false
      end)

    reference = {Quicksort, action.name}

    type =
      Enum.find_value(Aikido.Agent.Info.signal_routes(Quicksort), fn
        {type, ^reference, _} -> type
        {type, _, ^reference, _} -> type
        _ -> nil
      end)

    assert is_binary(type)
    signal = %Aikido.Signal{type: type, data: arguments, source: "/test/quicksort"}

    context =
      signal
      |> Aikido.Signal.ctx()
      |> Map.put(:agent, agent)
      |> Map.put(:agent_module, Quicksort)
      |> Map.put(:agent_id, agent.id)

    assert {:ok, %{agent: adopted}, directives} =
             Aikido.AgentServer.apply_actions(signal, context, [{reference, arguments}])

    {adopted, directives}
  end

  defp own(agent), do: Map.fetch!(agent.state, Aikido.Agent.Info.agent_path!(Quicksort))

  defp agent(child_attempts \\ %{}) do
    Quicksort.initialize!(%{
      id: "root",
      state: %{
        status: :sorting,
        branch: "root",
        topic: "test",
        numbers: [2, 1],
        pivot: 2,
        partitions: %{"L" => [1]},
        results: %{},
        started_children: %{},
        child_attempts: child_attempts,
        error: nil
      }
    })
  end
end
