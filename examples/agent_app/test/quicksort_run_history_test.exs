defmodule AgentExamples.Quicksort.RunHistoryTest do
  use ExUnit.Case, async: true
  alias AgentExamples.Quicksort.RunHistory

  test "display history survives subscriber exit and late events cannot reopen a closed run" do
    topic = RunHistory.topic(Ash.UUIDv7.generate())
    :ok = RunHistory.open(topic)
    assert :pending = RunHistory.elapsed(topic)
    node = %{branch: "root", id: "root", status: :completed, count: 1, pivot: 1}
    RunHistory.record(topic, node)
    assert {:ok, %{completed: 1}} = RunHistory.fetch(topic)

    assert {:ok, elapsed} = RunHistory.elapsed(topic)
    assert elapsed >= 0
    task = Task.async(fn -> RunHistory.fetch(topic) end)
    assert {:ok, %{completed: 1}} = Task.await(task)
    assert {:ok, %{nodes: %{"root" => ^node}}} = RunHistory.fetch(topic)

    RunHistory.record(topic, node)
    assert {:ok, ^elapsed} = RunHistory.elapsed(topic)
    :ok = RunHistory.close(topic)
    RunHistory.record(topic, node)
    assert :error = RunHistory.fetch(topic)
  end

  test "progress is coalesced before delivery and late events cannot regress terminal nodes" do
    topic = RunHistory.topic(Ash.UUIDv7.generate())
    :ok = RunHistory.open(topic)
    Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)
    on_exit(fn -> RunHistory.close(topic) end)
    node = %{branch: "root", id: "root", status: :sorting, count: 1, pivot: 1}
    RunHistory.record(topic, node)
    RunHistory.record(topic, %{node | status: :completed})
    for _ <- 1..1000, do: RunHistory.record(topic, %{node | status: :idle})
    assert {:ok, %{completed: 1}} = RunHistory.fetch(topic)

    assert_receive {:quicksort_progress_batch, ^topic, [%{branch: "root", status: :completed}]},
                   1_000

    refute_receive {:quicksort_progress_batch, ^topic, _}, 150
    refute_receive {:quicksort_progress, _, _}
  end

  test "closing a run drops its pending browser update" do
    topic = RunHistory.topic(Ash.UUIDv7.generate())
    :ok = RunHistory.open(topic)
    Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)
    RunHistory.record(topic, %{branch: "root", id: "root", status: :sorting, count: 1, pivot: 1})
    :ok = RunHistory.close(topic)
    refute_receive {:quicksort_progress_batch, ^topic, _}, 200
    assert :error = RunHistory.fetch(topic)
  end
end
