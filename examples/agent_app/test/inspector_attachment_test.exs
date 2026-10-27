defmodule AgentExamples.InspectorAttachmentTest do
  use ExUnit.Case, async: false
  alias AgentExamples.{Agents, Playground}

  test "attaching to an existing nested team discovers its current members recursively" do
    root = Agents.nested_team_start!(%{})
    on_exit(fn -> Agents.nested_team_stop(root) end)
    home = Agents.nested_team_inspect!(root).team.members[:home]
    counter = Agents.team_inspect!(home).team.members[:counter]
    {:ok, ref} = Aikido.Inspector.attach(root, &Playground.snapshot/2, include_children?: true)
    on_exit(fn -> Aikido.Inspector.detach(ref) end)
    Agents.counter_add!(counter, %{amount: 3})
    entries = await_entries(ref, [], &Enum.any?(&1, fn entry -> entry.agent_pid == counter end))
    assert Enum.any?(entries, &(&1.agent_pid == counter && &1.signal_type == "counter.add"))
  end

  test "an attachment follows newly spawned descendants even after their processes exit" do
    root = Agents.quicksort_start!(%{})
    other = Agents.counter_start!(%{})

    on_exit(fn ->
      Agents.quicksort_stop(root)
      Agents.counter_stop(other)
    end)

    {:ok, tree} = Aikido.Inspector.attach(root, &Playground.snapshot/2, include_children?: true)
    {:ok, single} = Aikido.Inspector.attach(root, &Playground.snapshot/2)

    on_exit(fn ->
      Aikido.Inspector.detach(tree)
      Aikido.Inspector.detach(single)
    end)

    Agents.counter_add!(other, %{amount: 1})

    signal =
      AgentExamples.Quicksort.Signals.Sort.new!(%{numbers: [4, 1, 3, 2], topic: "inspector-test"})

    assert {:ok, [1, 2, 3, 4]} =
             Aikido.AgentServer.call_until(
               root.pid,
               signal,
               "quicksort.**",
               fn runtime ->
                 state = runtime.agent.state.state
                 if state.status == :completed, do: {:ok, state.result}, else: :skip
               end,
               timeout: 15_000
             )

    entries =
      await_entries(tree, [], fn entries ->
        Enum.any?(entries, &(&1.agent_id != root.id && &1.signal_type == "quicksort.sort")) &&
          Enum.any?(entries, &(&1.agent_id == root.id && &1.signal_type == "quicksort.sorted"))
      end)

    assert Enum.any?(entries, &(length(String.split(&1.agent_id, "/")) >= 3))
    refute Enum.any?(entries, &(&1.agent_id == other.id))

    lifecycle =
      Enum.filter(entries, &String.starts_with?(&1.signal_type, "aikido.agent.lifecycle."))

    assert lifecycle != []
    assert Enum.all?(lifecycle, fn entry -> elem(entry.result, 1).execution.error == nil end)

    assert Enum.any?(entries, fn entry ->
             entry.agent_id != root.id &&
               entry.result |> elem(1) |> Map.get(:execution) |> Map.get(:actions) != []
           end)

    root_entries =
      await_entries(
        single,
        [],
        &Enum.any?(&1, fn entry -> entry.signal_type == "quicksort.sorted" end)
      )

    assert Enum.all?(root_entries, &(&1.agent_id == root.id))
  end

  test "attachments bound retained events and isolate projection failures" do
    root = Agents.counter_start!(%{})
    on_exit(fn -> Agents.counter_stop(root) end)

    {:ok, ref} =
      Aikido.Inspector.attach(
        root,
        fn
          _, %{signal: %{type: "counter.add"}} -> raise "projection failure"
          _, _ -> :skip
        end,
        limit: 2,
        flush_interval_ms: 200
      )

    for _ <- 1..6, do: Agents.counter_add!(root, %{amount: 1})
    assert_receive {:aikido_inspection, ^ref, %{sequence: 6, entries: entries}}, 5000
    assert length(entries) == 2
    assert Enum.map(entries, & &1.sequence) == [5, 6]
    assert Enum.all?(entries, &match?({:error, {:selector_raised, _, _}}, &1.result))
    assert Agents.counter_inspect!(root).count == 6
    assert :ok = Aikido.Inspector.detach(ref)
    refute :ets.member(Aikido.Inspector, ref)
  end

  defp await_entries(ref, entries, ready?) do
    if ready?.(entries) do
      entries
    else
      assert_receive {:aikido_inspection, ^ref, batch}, 5000
      await_entries(ref, entries ++ batch.entries, ready?)
    end
  end
end
