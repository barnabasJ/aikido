defmodule AikidoTest.DurableTest.ThreadAgent do
  use Aikido.Agent

  agent do
    name "durable_thread"
    slice :thread, Aikido.Slices.Thread
  end
end

defmodule AikidoTest.DurableTest.CodecSlice do
  use Aikido.Slice

  slice do
    name "durable_codec"

    schema do
      attribute :value, :integer, default: 3
    end
  end

  def externalize(state) do
    %{encoded: Integer.to_string(state.value)}
  end

  def reinstate(%{encoded: value}) do
    %{value: String.to_integer(value)}
  end
end

defmodule AikidoTest.DurableTest.CodecAgent do
  use Aikido.Agent

  agent do
    name "durable_codec_agent"
    path :domain

    schema do
      attribute :value, :integer, default: 5
      attribute :credential, :string
    end

    slice :codec, AikidoTest.DurableTest.CodecSlice
  end

  def externalize(state) do
    %{encoded: Integer.to_string(state.value)}
  end

  def reinstate(%{encoded: value}) do
    %{value: String.to_integer(value)}
  end

  @impl true
  def checkpoint(agent, _context) do
    {:ok, %{id: agent.id, custom_state: agent.state}}
  end

  @impl true
  def restore(checkpoint, _context) do
    agent = initialize!(%{id: checkpoint.id})
    {:ok, %{agent | state: checkpoint.custom_state}}
  end
end

defmodule AikidoTest.DurableTest do
  use ExUnit.Case, async: false

  setup do
    directory =
      Path.join(System.tmp_dir!(), "aikido-durable-#{System.unique_integer([:positive])}")

    instance = AikidoTest.DurableInstance
    start_supervised!({Aikido, name: instance, durable: []})

    opts = [
      name: AikidoTest.DurablePool,
      agent: AikidoTest.TestAgents.Counter,
      aikido: instance,
      data_dir: directory,
      durable_options: [discovery_interval_ms: 100, initial_discovery_delay_ms: 0]
    ]

    start_supervised!({Aikido.Durable, opts})
    on_exit(fn -> File.rm_rf!(directory) end)
    %{pool: AikidoTest.DurablePool, options: opts, directory: directory, instance: instance}
  end

  test("concurrent activation uses one native DurableServer", %{pool: pool}) do
    pids =
      1..12
      |> Task.async_stream(fn _ -> Aikido.Durable.ensure_started(pool, "shared") end)
      |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

    assert length(Enum.uniq(pids)) == 1
    assert %DurableServer{} = :sys.get_state(hd(pids))
    assert Aikido.Durable.lookup(pool, "shared") == {:ok, hd(pids)}
  end

  test("partitioned identities are independent", %{pool: pool}) do
    assert {:ok, alpha} = Aikido.Durable.ensure_started(pool, "shared", partition: :alpha)
    assert {:ok, beta} = Aikido.Durable.ensure_started(pool, "shared", partition: :beta)
    refute alpha == beta
    assert Aikido.Durable.lookup(pool, "shared", partition: :alpha) == {:ok, alpha}
    assert Aikido.Durable.lookup(pool, "shared", partition: :beta) == {:ok, beta}
    assert Aikido.Durable.lookup(pool, "shared") == :error
  end

  test("explicit stop restores acknowledged state from disk", %{pool: pool}) do
    {:ok, first} = Aikido.Durable.ensure_started(pool, {:conversation, 42})

    assert {:ok, 7} =
             Aikido.AgentServer.call(
               first,
               Jido.Signal.new!("increment", %{amount: 7}),
               &{:ok, &1.agent.state.domain.counter}
             )

    assert :ok = Aikido.Durable.stop(pool, {:conversation, 42})
    assert {:ok, second} = Aikido.Durable.ensure_started(pool, {:conversation, 42})
    refute first == second
    assert {:ok, 7} = Aikido.AgentServer.state(second, &{:ok, &1.agent.state.domain.counter})
  end

  test("an untrappable process crash recovers the last acknowledged state", %{pool: pool}) do
    {:ok, first} = Aikido.Durable.ensure_started(pool, "crash")

    assert {:ok, 9} =
             Aikido.AgentServer.call(
               first,
               Jido.Signal.new!("increment", %{amount: 9}),
               &{:ok, &1.agent.state.domain.counter}
             )

    second = AikidoTest.LifecycleWait.restart(first)

    assert {:ok, 9} = Aikido.AgentServer.state(second, &{:ok, &1.agent.state.domain.counter})
  end

  test("restarting storage and supervision restores the disk checkpoint", %{
    pool: pool,
    options: opts
  }) do
    {:ok, first} = Aikido.Durable.ensure_started(pool, "disk")

    assert {:ok, 4} =
             Aikido.AgentServer.call(
               first,
               Jido.Signal.new!("increment", %{amount: 4}),
               &{:ok, &1.agent.state.domain.counter}
             )

    stop_supervised!(pool)
    start_supervised!({Aikido.Durable, opts})
    assert {:ok, second} = Aikido.Durable.ensure_started(pool, "disk")
    assert {:ok, 4} = Aikido.AgentServer.state(second, &{:ok, &1.agent.state.domain.counter})
  end

  test("missing identities keep tagged error contracts", %{pool: pool}) do
    assert :error = Aikido.Durable.lookup(pool, "missing")
    assert {:error, :not_found} = Aikido.Durable.stop(pool, "missing")
  end

  test "thread history survives durable stop and activation", %{pool: pool} do
    {:ok, first} =
      Aikido.Durable.ensure_started(pool, "thread-history",
        agent: AikidoTest.DurableTest.ThreadAgent
      )

    {:ok, thread} =
      Aikido.AgentServer.call(
        first,
        Jido.Signal.new!("aikido.thread.append", %{
          entry: %{kind: :message, payload: %{text: "Keep this conversation"}}
        }),
        &{:ok, &1.agent.state.thread}
      )

    assert length(thread.entries) == 1
    assert :ok = Aikido.Durable.stop(pool, "thread-history")

    {:ok, second} =
      Aikido.Durable.ensure_started(pool, "thread-history",
        agent: AikidoTest.DurableTest.ThreadAgent
      )

    assert {:ok, ^thread} = Aikido.AgentServer.state(second, &{:ok, &1.agent.state.thread})

    assert {:ok, %{entries: entries, rev: 2}} =
             Aikido.AgentServer.call(
               second,
               Jido.Signal.new!("aikido.thread.append", %{
                 entry: %{kind: :message, payload: %{text: "Continue after restoration"}}
               }),
               &{:ok, &1.agent.state.thread}
             )

    assert length(entries) == 2
  end

  test "dynamic cron definitions restore and cancellation persists", %{pool: pool} do
    alias AikidoTest.Support.SchedulerIntegrationHarness

    opts = [agent: AikidoTest.Support.SchedulerIntegrationHarness.CronAgent]
    {:ok, first} = Aikido.Durable.ensure_started(pool, "scheduled", opts)
    :ok = SchedulerIntegrationHarness.register_cron(first, "0 0 0 1 1 *", job_id: :annual)
    old_job = SchedulerIntegrationHarness.wait_for_job(first, :annual)

    :ok = Aikido.Durable.stop(pool, "scheduled")
    {:ok, second} = Aikido.Durable.ensure_started(pool, "scheduled", opts)
    new_job = SchedulerIntegrationHarness.wait_for_job(second, :annual)
    refute old_job == new_job
    refute Process.alive?(old_job)

    :ok = SchedulerIntegrationHarness.cancel_cron(second, :annual)

    AikidoTest.AgentWait.await_state_value(second, fn state ->
      !Map.has_key?(state.cron_specs, :annual)
    end)

    :ok = Aikido.Durable.stop(pool, "scheduled")
    {:ok, third} = Aikido.Durable.ensure_started(pool, "scheduled", opts)
    assert :ok = Aikido.AgentServer.await_ready(third)

    assert {:ok, {%{}, %{}}} =
             Aikido.AgentServer.state(third, &{:ok, {&1.cron_jobs, &1.cron_specs}})
  end

  test("agent and slice codecs compose with custom checkpoint/restore", %{pool: pool}) do
    {:ok, first} =
      Aikido.Durable.ensure_started(pool, "codec", agent: AikidoTest.DurableTest.CodecAgent)

    durable = :sys.get_state(first)
    %{"payload" => encoded} = Aikido.Durable.AgentServer.dump_state(durable.user_state)
    snapshot = encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])

    assert {:checkpoint, %{custom_state: %{domain: %{encoded: "5"}, codec: %{encoded: "3"}}}} =
             snapshot.agent

    assert :ok = Aikido.Durable.stop(pool, "codec")

    {:ok, restored} =
      Aikido.Durable.ensure_started(pool, "codec", agent: AikidoTest.DurableTest.CodecAgent)

    assert {:ok, %{domain: %{value: 5}, codec: %{value: 3}}} =
             Aikido.AgentServer.state(restored, &{:ok, &1.agent.state})
  end

  test "initial and live snapshots both apply codecs to the only copy of startup state", %{
    pool: pool
  } do
    module = AikidoTest.DurableTest.CodecAgent

    options = [
      agent_module: module,
      id: "safe",
      initial_state: %{domain: %{value: 7, credential: "private-marker"}}
    ]

    dumped = Aikido.Durable.AgentServer.dump_state(%{options: options, permanent: true})
    saved = dumped["payload"] |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    refute inspect(saved) =~ "private-marker"
    refute Keyword.has_key?(saved.options, :initial_state)
    assert {:checkpoint, %{custom_state: %{domain: %{encoded: "7"}}}} = saved.agent

    {:ok, pid} =
      Aikido.Durable.ensure_started(pool, "safe",
        agent: module,
        initial_state: %{domain: %{value: 7, credential: "private-marker"}}
      )

    dumped = Aikido.Durable.AgentServer.dump_state(:sys.get_state(pid).user_state)
    saved = dumped["payload"] |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    refute inspect(saved) =~ "private-marker"
    refute Keyword.has_key?(saved.options, :initial_state)
    assert :ok = Aikido.Durable.stop(pool, "safe")
    {:ok, restored} = Aikido.Durable.ensure_started(pool, "safe", agent: module)
    assert {:ok, 7} = Aikido.AgentServer.state(restored, &{:ok, &1.agent.state.domain.value})
  end

  test("the default Aikido lifecycle uses DurableServer", %{directory: directory}) do
    instance = AikidoTest.DurableDefaultInstance

    start_supervised!(
      {Aikido, name: instance, durable: [data_dir: Path.join(directory, "default")]}
    )

    assert {:ok, pid} =
             Aikido.start_agent(instance, AikidoTest.TestAgents.Counter, id: "default-counter")

    assert %DurableServer{} = :sys.get_state(pid)
    assert Aikido.whereis(instance, "default-counter") == pid
    assert :ok = Aikido.stop_agent(instance, pid)
  end

  test("Ash teams recover their desired members and saved worker state", %{directory: directory}) do
    instance = AikidoTest.AshFixtures.Instance

    start_supervised!(
      {Aikido,
       name: instance,
       durable: [
         data_dir: Path.join(directory, "team"),
         durable_options: [discovery_interval_ms: 100, initial_discovery_delay_ms: 0]
       ]}
    )

    team = snapshot_result(AikidoTest.AshFixtures.Domain.dynamic_start!(%{id: "durable-team"}))

    team =
      snapshot_result(
        AikidoTest.AshFixtures.Domain.dynamic_add_member!(team, %{
          member: "counter",
          template: :counter,
          initial_state: %{count: 8}
        })
      )

    first = Aikido.whereis(instance, team.id)
    second = AikidoTest.LifecycleWait.restart(first)

    member =
      AikidoTest.AgentWait.await_state_value(
        second,
        fn state ->
          if state.agent.state.team.operation.status == :completed do
            state.agent.state.team.members["counter"]
          end
        end,
        timeout: 10000
      )

    assert Process.alive?(member)
    assert {:ok, 8} = Aikido.AgentServer.state(member, &{:ok, &1.agent.state.state.count})
    assert :ok = Aikido.stop_agent(instance, second)

    resumed =
      snapshot_result(AikidoTest.AshFixtures.Domain.dynamic_start!(%{id: team.id, topology: %{}}))

    assert Map.has_key?(resumed.team.topology.nodes, "counter")
    resumed_pid = Aikido.whereis(instance, team.id)

    worker =
      AikidoTest.AgentWait.await_state_value(
        resumed_pid,
        fn state ->
          if state.agent.state.team.operation.status == :completed do
            state.agent.state.team.members["counter"]
          end
        end,
        timeout: 10000
      )

    assert Process.alive?(worker)
  end

  defp snapshot_result({:ok, %{resource: resource, id: id}}) do
    Aikido.Ash.inspect(resource, id)
  end

  defp snapshot_result({:error, _} = error) do
    error
  end

  defp snapshot_result(%{resource: resource, id: id}) do
    Aikido.Ash.inspect!(resource, id)
  end
end
