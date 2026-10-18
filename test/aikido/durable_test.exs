defmodule AikidoTest.DurableTest do
  use ExUnit.Case, async: false
  import AikidoTest.Eventually
  alias Aikido.{AgentServer, Durable}
  alias Jido.Signal
  alias AikidoTest.TestAgents.Counter

  defmodule CodecSlice do
    use Aikido.Slice

    slice do
      name "durable_codec"

      schema do
        attribute :value, :integer, default: 3
      end
    end

    def externalize(state), do: %{encoded: Integer.to_string(state.value)}
    def reinstate(%{encoded: value}), do: %{value: String.to_integer(value)}
  end

  defmodule CodecAgent do
    use Aikido.Agent

    agent do
      name "durable_codec_agent"
      path :domain

      schema do
        attribute :value, :integer, default: 5
      end
    end

    slices do
      slice :codec, CodecSlice
    end

    def externalize(state), do: %{encoded: Integer.to_string(state.value)}
    def reinstate(%{encoded: value}), do: %{value: String.to_integer(value)}
    def checkpoint(agent, _context), do: {:ok, %{id: agent.id, custom_state: agent.state}}

    def restore(checkpoint, _context) do
      agent = new(id: checkpoint.id)
      {:ok, %{agent | state: checkpoint.custom_state}}
    end
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "aikido-durable-#{System.unique_integer([:positive])}")

    instance = AikidoTest.DurableInstance
    start_supervised!({Aikido, name: instance, durable: false})

    opts = [
      name: AikidoTest.DurablePool,
      agent: Counter,
      aikido: instance,
      data_dir: directory,
      durable_options: [discovery_interval_ms: 100]
    ]

    start_supervised!({Durable, opts})
    on_exit(fn -> File.rm_rf!(directory) end)
    %{pool: AikidoTest.DurablePool, options: opts, directory: directory, instance: instance}
  end

  test "concurrent activation uses one native DurableServer", %{pool: pool} do
    pids =
      1..12
      |> Task.async_stream(fn _ -> Durable.ensure_started(pool, "shared") end)
      |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

    assert length(Enum.uniq(pids)) == 1
    assert %DurableServer{} = :sys.get_state(hd(pids))
    assert Durable.lookup(pool, "shared") == {:ok, hd(pids)}
    assert Durable.stats(pool) == %{count: 1, keys: ["shared"]}
    assert Durable.agent_module(pool) == {:ok, Counter}
  end

  test "partitioned identities are independent", %{pool: pool} do
    assert {:ok, alpha} = Durable.ensure_started(pool, "shared", partition: :alpha)
    assert {:ok, beta} = Durable.ensure_started(pool, "shared", partition: :beta)
    refute alpha == beta
    assert Durable.lookup(pool, "shared", partition: :alpha) == {:ok, alpha}
    assert Durable.lookup(pool, "shared", partition: :beta) == {:ok, beta}
    assert Durable.lookup(pool, "shared") == :error
  end

  test "explicit stop restores acknowledged state from disk", %{pool: pool} do
    {:ok, first} = Durable.ensure_started(pool, {:conversation, 42})

    assert {:ok, 7} =
             AgentServer.call(
               first,
               Signal.new!("increment", %{amount: 7}),
               &{:ok, &1.agent.state.domain.counter}
             )

    assert :ok = Durable.stop(pool, {:conversation, 42})
    assert {:ok, second} = Durable.ensure_started(pool, {:conversation, 42})
    refute first == second
    assert {:ok, 7} = AgentServer.state(second, &{:ok, &1.agent.state.domain.counter})
  end

  test "an untrappable process crash recovers the last acknowledged state", %{pool: pool} do
    {:ok, first} = Durable.ensure_started(pool, "crash")

    assert {:ok, 9} =
             AgentServer.call(
               first,
               Signal.new!("increment", %{amount: 9}),
               &{:ok, &1.agent.state.domain.counter}
             )

    Process.exit(first, :kill)

    second =
      eventually(
        fn ->
          case Durable.lookup(pool, "crash") do
            {:ok, pid} when pid != first -> pid
            _ -> false
          end
        end,
        timeout: 10_000
      )

    assert {:ok, 9} = AgentServer.state(second, &{:ok, &1.agent.state.domain.counter})
  end

  test "restarting storage and supervision restores the disk checkpoint", %{
    pool: pool,
    options: opts
  } do
    {:ok, first} = Durable.ensure_started(pool, "disk")

    assert {:ok, 4} =
             AgentServer.call(
               first,
               Signal.new!("increment", %{amount: 4}),
               &{:ok, &1.agent.state.domain.counter}
             )

    stop_supervised!(pool)
    start_supervised!({Durable, opts})
    assert {:ok, second} = Durable.ensure_started(pool, "disk")
    assert {:ok, 4} = AgentServer.state(second, &{:ok, &1.agent.state.domain.counter})
  end

  test "missing identities keep tagged error contracts", %{pool: pool} do
    assert :error = Durable.lookup(pool, "missing")
    assert {:error, :not_found} = Durable.stop(pool, "missing")
  end

  test "agent and slice codecs compose with custom checkpoint/restore", %{pool: pool} do
    {:ok, first} = Durable.ensure_started(pool, "codec", agent: CodecAgent)
    durable = :sys.get_state(first)
    %{"payload" => encoded} = Aikido.Durable.AgentServer.dump_state(durable.user_state)
    snapshot = encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])

    assert {:checkpoint, %{custom_state: %{domain: %{encoded: "5"}, codec: %{encoded: "3"}}}} =
             snapshot.agent

    assert :ok = Durable.stop(pool, "codec")
    {:ok, restored} = Durable.ensure_started(pool, "codec", agent: CodecAgent)

    assert {:ok, %{domain: %{value: 5}, codec: %{value: 3}}} =
             AgentServer.state(restored, &{:ok, &1.agent.state})
  end

  test "the default Aikido lifecycle uses DurableServer", %{directory: directory} do
    instance = AikidoTest.DurableDefaultInstance

    start_supervised!(
      {Aikido, name: instance, durable: [data_dir: Path.join(directory, "default")]}
    )

    assert {:ok, pid} = Aikido.start_agent(instance, Counter, id: "default-counter")
    assert %DurableServer{} = :sys.get_state(pid)
    assert Aikido.whereis(instance, "default-counter") == pid
    assert :ok = Aikido.stop_agent(instance, pid)
  end

  test "Ash teams recover their desired members and saved worker state", %{directory: directory} do
    instance = AikidoTest.AshFixtures.Instance

    start_supervised!(
      {Aikido,
       name: instance,
       durable: [
         data_dir: Path.join(directory, "team"),
         durable_options: [discovery_interval_ms: 100]
       ]}
    )

    alias AikidoTest.AshFixtures.Domain
    team = snapshot_result(Domain.dynamic_start!(%{id: "durable-team"}))

    team =
      snapshot_result(
        Domain.dynamic_add_member!(team, %{
          member: "counter",
          template: :counter,
          initial_state: %{count: 8}
        })
      )

    first = Aikido.whereis(instance, team.id)
    Process.exit(first, :kill)

    second =
      eventually(
        fn ->
          case Aikido.whereis(instance, team.id) do
            pid when is_pid(pid) and pid != first -> pid
            _ -> false
          end
        end,
        timeout: 10_000
      )

    member =
      AikidoTest.AgentWait.await_state_value(
        second,
        fn state ->
          if state.agent.state.team.operation.status == :completed,
            do: state.agent.state.team.members["counter"]
        end,
        timeout: 10_000
      )

    assert Process.alive?(member)
    assert {:ok, 8} = AgentServer.state(member, &{:ok, &1.agent.state.state.count})
    assert :ok = Aikido.stop_agent(instance, second)
    resumed = snapshot_result(Domain.dynamic_start!(%{id: team.id, topology: %{}}))
    assert Map.has_key?(resumed.team.topology.nodes, "counter")
    resumed_pid = Aikido.whereis(instance, team.id)

    worker =
      AikidoTest.AgentWait.await_state_value(
        resumed_pid,
        fn state ->
          if state.agent.state.team.operation.status == :completed,
            do: state.agent.state.team.members["counter"]
        end,
        timeout: 10_000
      )

    assert Process.alive?(worker)
  end

  # Commands return receipts; state assertions opt into a separate inspection.
  defp snapshot_result({:ok, %{resource: resource, id: id}}),
    do: Aikido.Ash.inspect(resource, id)

  defp snapshot_result({:error, _} = error), do: error

  defp snapshot_result(%{resource: resource, id: id}),
    do: Aikido.Ash.inspect!(resource, id)
end
