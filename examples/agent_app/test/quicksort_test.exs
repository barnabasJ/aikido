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
        assert_receive {:partition_ready, id, pid}, 5000
        {id, pid, Process.monitor(pid)}
      end

    for {id, pid, monitor} <- children do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 10_000

      assert {:error, :not_found} =
               Aikido.Durable.delete(
                 Aikido.durable_supervisor_name(Aikido.Default),
                 id,
                 agent: AgentExamples.Quicksort
               )
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

  test "playground stop resolves a replacement process instead of trusting its old PID" do
    owner = "stale-stop:" <> Ash.UUIDv7.generate()
    {:ok, run} = AgentExamples.Playground.start(owner, "quicksort", %{})
    Agents.quicksort_stop!(run.record)
    replacement = Agents.quicksort_start!(%{id: run.record.id})
    on_exit(fn -> Agents.quicksort_stop(replacement) end)
    monitor = Process.monitor(replacement.pid)

    assert :ok = AgentExamples.Playground.stop(owner, "quicksort")
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5000
    assert AgentExamples.Playground.get(owner, "quicksort").status == :stopped

    assert :error =
             Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), run.record.id)
  end

  test "empty and equal-valued inputs complete without children" do
    for numbers <- [[], [3], [3, 3, 3]] do
      root = Agents.quicksort_start!(%{})
      on_exit(fn -> Agents.quicksort_stop(root) end)
      Agents.quicksort_sort!(root, %{numbers: numbers, topic: "sort-test"})

      assert {:ok, {result, children}} =
               Aikido.AgentServer.state(root.pid, fn runtime ->
                 {:ok, {runtime.agent.state.state.result, Aikido.Ownership.children(runtime)}}
               end)

      assert result == numbers
      assert children == %{}
    end
  end

  test "restart deletes a recorded inactive worker crash checkpoint without scanning other trees" do
    owner = "crash-checkpoint:" <> Ash.UUIDv7.generate()
    {:ok, run} = AgentExamples.Playground.start(owner, "quicksort", %{})
    pool = Aikido.durable_supervisor_name(Aikido.Default)
    id = Aikido.Agent.child_id(run.record.id, "L")
    topic = run.snapshot.own.topic
    AgentExamples.Quicksort.RunHistory.open(topic)

    AgentExamples.Quicksort.RunHistory.record(topic, %{
      id: id,
      branch: "rootL",
      status: :sorting,
      count: 1,
      pivot: 63
    })

    child =
      AgentExamples.Quicksort
      |> Ash.ActionInput.for_action(:start, %{id: id},
        context: %{aikido_runtime_options: [restart?: false]}
      )
      |> Ash.run_action!()

    {storage_key, _} =
      Enum.find(DurableServer.Supervisor.global_members(pool), fn {_, {pid, _}} ->
        pid == child.pid
      end)

    monitor = Process.monitor(child.pid)
    Process.exit(child.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 5000
    assert {:ok, _saved} = DurableServer.Supervisor.get_server_info(pool, storage_key)
    on_exit(fn -> AgentExamples.Playground.stop(owner, "quicksort") end)

    assert {:ok, fresh} = AgentExamples.Quicksort.Restart.restart(owner)
    refute fresh.record.id == run.record.id
    assert {:error, :not_found} = DurableServer.Supervisor.get_server_info(pool, storage_key)

    replacement = Agents.quicksort_start!(%{id: id})
    on_exit(fn -> Agents.quicksort_stop(replacement) end)

    assert {:ok, :idle} =
             Aikido.AgentServer.state(replacement.pid, &{:ok, &1.agent.state.state.status})
  end

  test "restart reconstructs child identities when display history is unavailable" do
    owner = "lost-history:" <> Ash.UUIDv7.generate()
    {:ok, run} = AgentExamples.Playground.start(owner, "quicksort", %{})
    on_exit(fn -> AgentExamples.Playground.stop(owner, "quicksort") end)
    signal = AgentExamples.Quicksort.Signals.Sort.new!(%{numbers: [3, 1, 2], topic: owner})

    assert {:ok, [1, 2, 3]} =
             Aikido.AgentServer.call_until(
               run.record.pid,
               signal,
               "quicksort.**",
               fn runtime ->
                 if runtime.agent.state.state.status == :completed,
                   do: {:ok, runtime.agent.state.state.result},
                   else: :skip
               end
             )

    # Reproduce an inactive checkpoint at a real partition identity with no UI index.
    id = Aikido.Agent.child_id(run.record.id, "R")
    pool = Aikido.durable_supervisor_name(Aikido.Default)

    case Aikido.Durable.lookup(pool, id) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5000

      :error ->
        :ok
    end

    child =
      AgentExamples.Quicksort
      |> Ash.ActionInput.for_action(:start, %{id: id},
        context: %{aikido_runtime_options: [restart?: false]}
      )
      |> Ash.run_action!()

    monitor = Process.monitor(child.pid)
    Process.exit(child.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 5000
    AgentExamples.Quicksort.RunHistory.close(owner)

    assert {:ok, _fresh} = AgentExamples.Quicksort.Restart.restart(owner)

    assert {:error, :not_found} =
             Aikido.Durable.delete(
               Aikido.durable_supervisor_name(Aikido.Default),
               id,
               agent: AgentExamples.Quicksort
             )
  end

  test "repeated shuffled sorts isolate each execution and release its processes and history" do
    owner = "repeat-test:" <> Ash.UUIDv7.generate()
    {:ok, _initial} = AgentExamples.Playground.start(owner, "quicksort", %{})
    handler = {__MODULE__, make_ref()}

    on_exit(fn ->
      :telemetry.detach(handler)
      AgentExamples.Playground.stop(owner, "quicksort")
    end)

    identities =
      for _ <- 1..10, reduce: MapSet.new() do
        identities ->
          root = AgentExamples.Playground.get(owner, "quicksort").record

          :ok =
            :telemetry.attach(
              handler,
              [:aikido, :agent_server, :ready],
              &__MODULE__.capture_partition/4,
              {self(), root.id}
            )

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

          :telemetry.detach(handler)
          {:ok, fresh} = AgentExamples.Quicksort.Restart.restart(owner)
          refute fresh.record.id == root.id
          refute fresh.record.pid == root.pid
          assert fresh.snapshot.own.status == :idle
          assert :error == AgentExamples.Quicksort.RunHistory.fetch(topic)
          identities
      end

    assert MapSet.size(identities) == 310
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
    refute fresh.record.id == initial.record.id
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

  test "restart checkpoints the shared store without stopping another owned tree" do
    owner = "checkpoint-restart:" <> Ash.UUIDv7.generate()
    other_owner = "checkpoint-independent:" <> Ash.UUIDv7.generate()
    {:ok, initial} = AgentExamples.Playground.start(owner, "quicksort", %{})
    {:ok, other} = AgentExamples.Playground.start(other_owner, "quicksort", %{})

    on_exit(fn ->
      AgentExamples.Playground.stop(owner, "quicksort")
      AgentExamples.Playground.stop(other_owner, "quicksort")
    end)

    numbers = Enum.to_list(1..16)

    signal =
      AgentExamples.Quicksort.Signals.Sort.new!(%{
        numbers: Enum.reverse(numbers),
        topic: "independent"
      })

    assert {:ok, ^numbers} =
             Aikido.AgentServer.call_until(
               other.record.pid,
               signal,
               "quicksort.**",
               fn runtime ->
                 state = runtime.agent.state.state
                 if state.status == :completed, do: {:ok, state.result}, else: :skip
               end,
               timeout: 30_000
             )

    assert {:ok, fresh} = AgentExamples.Quicksort.Restart.restart(owner)
    refute fresh.record.pid == initial.record.pid
    assert Process.alive?(other.record.pid)

    assert {:ok, ^numbers} =
             Aikido.AgentServer.state(other.record.pid, &{:ok, &1.agent.state.state.result})
  end

  def capture_partition(_event, _measurements, metadata, {owner, root_id}) do
    if String.starts_with?(metadata.agent_id, root_id <> "/") do
      send(owner, {:partition_ready, metadata.agent_id, self()})
    end
  end
end
