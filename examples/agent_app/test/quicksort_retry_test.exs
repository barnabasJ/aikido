defmodule AgentExamples.Quicksort.RetryTest do
  use ExUnit.Case, async: true
  alias AgentExamples.Quicksort.Actions.{RetryChild, ScheduleChildRetry, StartChild}

  test "a transient activation failure preserves the partition and retries with backoff" do
    state = state()

    {:ok, scheduled} =
      ScheduleChildRetry.run(input(state, %{tag: "L", reason: :timeout}), [], %{})

    assert scheduled.state.partitions == state.partitions
    assert scheduled.state.child_attempts == %{"L" => 1}
    assert [%Aikido.Directives.Schedule{delay_ms: 500, message: retry}] = scheduled.directives
    {:ok, retried} = RetryChild.run(input(scheduled.state, retry.data), [], %{})
    assert [%Aikido.Directives.SpawnAgent{tag: "L"}] = retried.directives
    assert retried.state == scheduled.state
  end

  test "late readiness supersedes a scheduled retry and stale generations do nothing" do
    state = %{state() | child_attempts: %{"L" => 2}}
    {:ok, stale} = RetryChild.run(input(state, %{tag: "L", attempt: 1}), [], %{})
    assert stale.directives == []

    {:ok, ready} =
      StartChild.run(input(state, %{tag: "L", pid: self(), child_id: "root/L"}), [], %{})

    {:ok, retry} = RetryChild.run(input(ready.state, %{tag: "L", attempt: 2}), [], %{})
    assert retry.directives == []

    {:ok, ignored} =
      ScheduleChildRetry.run(input(ready.state, %{tag: "L", reason: :timeout}), [], %{})

    assert ignored.directives == []
  end

  test "exhaustion terminates the partition and cancellation prevents retry" do
    state = %{state() | child_attempts: %{"L" => 8}}
    {:ok, failed} = ScheduleChildRetry.run(input(state, %{tag: "L", reason: :timeout}), [], %{})
    assert failed.state.status == :failed
    assert failed.state.error.reason == :timeout
    {:ok, ignored} = RetryChild.run(input(failed.state, %{tag: "L", attempt: 8}), [], %{})
    assert ignored.directives == []
  end

  defp input(state, arguments),
    do: %{arguments: Map.put(arguments, :state, state), context: %{aikido: %{agent_id: "root"}}}

  defp state,
    do: %{
      root_id: "root",
      status: :sorting,
      branch: "root",
      topic: "test",
      numbers: [2, 1],
      pivot: 2,
      partitions: %{"L" => [1]},
      results: %{},
      started_children: %{},
      child_attempts: %{},
      error: nil
    }
end
