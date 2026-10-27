defmodule AgentExamples.Quicksort.RunHistoryTest do
  use ExUnit.Case, async: true
  alias AgentExamples.Quicksort.RunHistory

  test "display history survives subscriber exit and late events cannot reopen a closed run" do
    topic = RunHistory.topic(Ash.UUIDv7.generate())
    :ok = RunHistory.open(topic)
    node = %{branch: "root", id: "root", status: :completed, count: 1, pivot: 1}
    RunHistory.record(topic, node)
    assert {:ok, %{completed: 1}} = RunHistory.fetch(topic)

    task = Task.async(fn -> RunHistory.fetch(topic) end)
    assert {:ok, %{completed: 1}} = Task.await(task)
    assert {:ok, %{nodes: %{"root" => ^node}}} = RunHistory.fetch(topic)

    :ok = RunHistory.close(topic)
    RunHistory.record(topic, node)
    assert :error = RunHistory.fetch(topic)
  end
end
