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
    pool = Aikido.durable_supervisor_name(Aikido.Default)

    owned =
      Aikido.Durable.members(pool)
      |> Enum.filter(fn {id, _} -> id == root.id || String.starts_with?(id, root.id <> "/") end)

    assert length(owned) == length(Enum.uniq(numbers))
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

  test "stopping a complete tree removes every descendant while preserving another owned root" do
    root = Agents.quicksort_start!(%{})
    other = Agents.quicksort_start!(%{})

    on_exit(fn ->
      Agents.quicksort_stop(root)
      Agents.quicksort_stop(other)
    end)

    numbers = Enum.to_list(1..128)
    signal = AgentExamples.Quicksort.Signals.Sort.new!(%{numbers: numbers, topic: "cleanup-test"})

    assert {:ok, ^numbers} =
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

    pool = Aikido.durable_supervisor_name(Aikido.Default)

    owned =
      Aikido.Durable.members(pool)
      |> Enum.filter(fn {id, _} -> id == root.id || String.starts_with?(id, root.id <> "/") end)

    assert length(owned) == 128
    monitors = Enum.map(owned, fn {_, pid} -> {pid, Process.monitor(pid)} end)
    Agents.quicksort_stop!(root)

    for {pid, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 10_000)

    assert Process.alive?(other.pid)

    refute Enum.any?(Aikido.Durable.members(pool), fn {id, pid} ->
             Process.alive?(pid) && (id == root.id || String.starts_with?(id, root.id <> "/"))
           end)
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
