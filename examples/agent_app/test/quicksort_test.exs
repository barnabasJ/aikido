defmodule AgentExamples.QuicksortTest do
  use ExUnit.Case, async: false
  alias AgentExamples.Agents

  test "sorted partitions retire while their root and recorded graph remain available" do
    topic = "sort-test:" <> Ash.UUIDv7.generate()
    Phoenix.PubSub.subscribe(AgentExamples.PubSub, topic)
    root = Agents.quicksort_start!(%{})
    on_exit(fn -> Agents.quicksort_stop(root) end)
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:aikido, :agent_server, :ready],
        &__MODULE__.capture_partition/4,
        {self(), root.id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
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

    children =
      for _ <- 1..(length(Enum.uniq(numbers)) - 1) do
        assert_receive {:partition_ready, _id, pid}, 5000
        {pid, Process.monitor(pid)}
      end

    for {pid, monitor} <- children do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 10_000
    end

    assert Process.alive?(root.pid)
    pool = Aikido.durable_supervisor_name(Aikido.Default)

    assert Enum.filter(Aikido.Durable.members(pool), fn {id, _} ->
             id == root.id || String.starts_with?(id, root.id <> "/")
           end) == [{root.id, root.pid}]

    assert_receive {:quicksort_progress, ^topic, %{status: :idle, branch: "rootL"}}, 5000
    assert_receive {:quicksort_progress, ^topic, %{status: :completed, branch: "root"}}, 5000
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

    assert length(owned) in 1..128
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

  test "repeated shuffled sorts reuse durable identities and release each recorded history" do
    owner = "repeat-test:" <> Ash.UUIDv7.generate()
    {:ok, initial} = AgentExamples.Playground.start(owner, "quicksort", %{})
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:aikido, :agent_server, :ready],
        &__MODULE__.capture_partition/4,
        {self(), initial.record.id}
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      AgentExamples.Playground.stop(owner, "quicksort")
    end)

    identities =
      for _ <- 1..10, reduce: MapSet.new() do
        identities ->
          root = AgentExamples.Playground.get(owner, "quicksort").record
          topic = AgentExamples.Quicksort.RunHistory.topic(Ash.UUIDv7.generate())
          AgentExamples.Quicksort.RunHistory.open(topic)
          numbers = Enum.shuffle(Enum.to_list(1..32))
          signal = AgentExamples.Quicksort.Signals.Sort.new!(%{numbers: numbers, topic: topic})

          assert {:ok, result} =
                   Aikido.AgentServer.call_until(
                     root.pid,
                     signal,
                     "quicksort.**",
                     fn runtime ->
                       state = runtime.agent.state.state

                       if state.status == :completed && state.topic == topic,
                         do: {:ok, state.result},
                         else: :skip
                     end,
                     timeout: 30_000
                   )

          assert result == Enum.to_list(1..32)

          identities =
            for _ <- 1..31, reduce: identities do
              identities ->
                assert_receive {:partition_ready, id, pid}, 5000
                ref = Process.monitor(pid)
                assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
                MapSet.put(identities, id)
            end

          {:ok, fresh} = AgentExamples.Quicksort.Restart.restart(owner)
          assert fresh.record.id == root.id
          refute fresh.record.pid == root.pid
          assert fresh.snapshot.own.status == :idle
          assert :error == AgentExamples.Quicksort.RunHistory.fetch(topic)
          identities
      end

    assert MapSet.size(identities) <= 32
  end

  test "an active sort can be restarted and its replacement completes independently" do
    owner = "active-restart:" <> Ash.UUIDv7.generate()
    {:ok, initial} = AgentExamples.Playground.start(owner, "quicksort", %{})
    on_exit(fn -> AgentExamples.Playground.stop(owner, "quicksort") end)
    old_topic = AgentExamples.Quicksort.RunHistory.topic(Ash.UUIDv7.generate())
    AgentExamples.Quicksort.RunHistory.open(old_topic)

    AgentExamples.Playground.command(owner, "quicksort", :sort, %{
      numbers: Enum.shuffle(Enum.to_list(1..1024)),
      topic: old_topic
    })

    {:ok, fresh} = AgentExamples.Quicksort.Restart.restart(owner)
    assert fresh.record.id == initial.record.id
    refute Process.alive?(initial.record.pid)
    assert fresh.snapshot.own.status == :idle

    signal =
      AgentExamples.Quicksort.Signals.Sort.new!(%{
        numbers: Enum.shuffle(Enum.to_list(1..64)),
        topic: "replacement"
      })

    assert {:ok, result} =
             Aikido.AgentServer.call_until(
               fresh.record.pid,
               signal,
               "quicksort.**",
               fn runtime ->
                 state = runtime.agent.state.state
                 if state.status == :completed, do: {:ok, state.result}, else: :skip
               end,
               timeout: 30_000
             )

    assert result == Enum.to_list(1..64)
  end

  def capture_partition(_event, _measurements, metadata, {owner, root_id}) do
    if String.starts_with?(metadata.agent_id, root_id <> "/") do
      send(owner, {:partition_ready, metadata.agent_id, self()})
    end
  end
end
