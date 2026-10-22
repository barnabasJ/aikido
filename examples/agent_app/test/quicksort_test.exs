defmodule AgentExamples.QuicksortTest do
  use ExUnit.Case, async: false
  alias AgentExamples.Agents

  test "real partition agents sort duplicates and negatives and stop with their parent" do
    topic = "sort-test:" <> Ash.UUIDv7.generate()
    Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)
    root = Agents.quicksort_start!(%{})
    on_exit(fn -> Agents.quicksort_stop(root) end)
    numbers = [9, -2, 4, 4, 0, 17, 1, -5, 8]
    signal = AgentExamples.Quicksort.Signals.Sort.new!(%{numbers: numbers, topic: topic})

    assert {:ok, sorted} =
             Aikido.AgentServer.call_until(
               root.pid,
               signal,
               "quicksort.**",
               fn runtime ->
                 state = runtime.agent.state.state
                 if state.status == :completed, do: {:ok, state.result}, else: :skip
               end,
               timeout: 30_000
             )

    assert sorted == Enum.sort(numbers)
    tree = AgentExamples.Quicksort.TreeSnapshot.read(root.pid)
    assert map_size(tree) == length(Enum.uniq(numbers))
    assert Enum.all?(tree, fn {_, node} -> node.status == :completed end)
    assert_receive {:quicksort_progress, ^topic, %{status: :idle, branch: "rootL"}}, 5000
    assert_receive {:quicksort_progress, ^topic, %{status: :completed, branch: "root"}}, 5000
    {:ok, children} = Aikido.AgentServer.state(root.pid, &{:ok, &1.children})
    assert map_size(children) == 2
    monitors = for {_, child} <- children, do: {child.pid, Process.monitor(child.pid)}
    Agents.quicksort_stop!(root)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 10_000
    end
  end

  test "empty and equal-valued inputs complete without children" do
    for numbers <- [[], [3], [3, 3, 3]] do
      root = Agents.quicksort_start!(%{})
      on_exit(fn -> Agents.quicksort_stop(root) end)
      Agents.quicksort_sort!(root, %{numbers: numbers, topic: "sort-test"})

      assert {:ok, {result, children}} =
               Aikido.AgentServer.state(root.pid, fn runtime ->
                 {:ok, {runtime.agent.state.state.result, runtime.children}}
               end)

      assert result == numbers
      assert children == %{}
    end
  end
end
