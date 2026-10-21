defmodule AikidoTest.DurableTest.ThreadAgent do
  use Aikido.Agent

  agent do
    name "durable_thread"
    slice :thread, Aikido.Thread.Slice
  end
end

defmodule AikidoTest.DurableTest.CodecSlice do
  use Aikido.Slice

  slice do
    name "durable_codec"

    schema do
      attribute :value, :integer do
        description "Domain value used to verify state transitions and native contracts."
        default 3
      end
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
      attribute :value, :integer do
        description "Domain value used to verify state transitions and native contracts."
        default 5
      end

      attribute :credential, :string do
        description "Credential used to verify checkpoint redaction."
      end
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
    if observer = Process.whereis(AikidoTest.DurableTest.InitObserver) do
      send(observer, {:restoring_checkpoint, self()})

      receive do
        :resume_restore -> :ok
      end
    end

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
      name: AikidoTest.DurableSupervisor,
      agent: AikidoTest.TestAgents.Counter,
      aikido: instance,
      data_dir: directory,
      durable_options: [discovery_interval_ms: 100, initial_discovery_delay_ms: 0]
    ]

    start_supervised!({Aikido.Durable, opts})
    on_exit(fn -> File.rm_rf!(directory) end)

    %{
      durable: AikidoTest.DurableSupervisor,
      options: opts,
      directory: directory,
      instance: instance
    }
  end

  test("concurrent activation uses one native DurableServer", %{durable: durable}) do
    pids =
      1..12
      |> Task.async_stream(fn _ -> Aikido.Durable.ensure_started(durable, "shared") end)
      |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

    assert length(Enum.uniq(pids)) == 1
    assert %DurableServer{} = :sys.get_state(hd(pids))
    assert Aikido.Durable.lookup(durable, "shared") == {:ok, hd(pids)}
  end

  test("partitioned identities are independent", %{durable: durable}) do
    assert {:ok, alpha} = Aikido.Durable.ensure_started(durable, "shared", partition: :alpha)
    assert {:ok, beta} = Aikido.Durable.ensure_started(durable, "shared", partition: :beta)
    refute alpha == beta
    assert Aikido.Durable.lookup(durable, "shared", partition: :alpha) == {:ok, alpha}
    assert Aikido.Durable.lookup(durable, "shared", partition: :beta) == {:ok, beta}
    assert Aikido.Durable.lookup(durable, "shared") == :error
  end

  test("explicit stop restores acknowledged state from disk", %{durable: durable}) do
    {:ok, first} = Aikido.Durable.ensure_started(durable, {:conversation, 42})

    assert {:ok, 7} =
             Aikido.AgentServer.call(
               first,
               Aikido.Signal.new!("increment", %{amount: 7}),
               &{:ok, &1.agent.state.domain.counter}
             )

    assert :ok = Aikido.Durable.stop(durable, {:conversation, 42})
    assert {:ok, second} = Aikido.Durable.ensure_started(durable, {:conversation, 42})
    refute first == second
    assert {:ok, 7} = Aikido.AgentServer.state(second, &{:ok, &1.agent.state.domain.counter})
  end

  test("an untrappable process crash recovers the last acknowledged state", %{durable: durable}) do
    {:ok, first} = Aikido.Durable.ensure_started(durable, "crash")

    assert {:ok, 9} =
             Aikido.AgentServer.call(
               first,
               Aikido.Signal.new!("increment", %{amount: 9}),
               &{:ok, &1.agent.state.domain.counter}
             )

    second = AikidoTest.LifecycleWait.restart(first)

    assert {:ok, 9} = Aikido.AgentServer.state(second, &{:ok, &1.agent.state.domain.counter})
  end

  test("restarting storage and supervision restores the disk checkpoint", %{
    durable: durable,
    options: opts
  }) do
    {:ok, first} = Aikido.Durable.ensure_started(durable, "disk")

    assert {:ok, 4} =
             Aikido.AgentServer.call(
               first,
               Aikido.Signal.new!("increment", %{amount: 4}),
               &{:ok, &1.agent.state.domain.counter}
             )

    stop_supervised!(durable)
    start_supervised!({Aikido.Durable, opts})
    assert {:ok, second} = Aikido.Durable.ensure_started(durable, "disk")
    assert {:ok, 4} = Aikido.AgentServer.state(second, &{:ok, &1.agent.state.domain.counter})
  end

  test("missing identities keep tagged error contracts", %{durable: durable}) do
    assert :error = Aikido.Durable.lookup(durable, "missing")
    assert {:error, :not_found} = Aikido.Durable.stop(durable, "missing")
  end

  test "thread history survives durable stop and activation", %{durable: durable} do
    {:ok, first} =
      Aikido.Durable.ensure_started(durable, "thread-history",
        agent: AikidoTest.DurableTest.ThreadAgent
      )

    {:ok, thread} =
      Aikido.AgentServer.call(
        first,
        Aikido.Signal.new!("aikido.thread.append", %{
          entry: %{kind: :message, payload: %{text: "Keep this conversation"}}
        }),
        &{:ok, &1.agent.state.thread}
      )

    assert length(thread.entries) == 1
    assert :ok = Aikido.Durable.stop(durable, "thread-history")

    {:ok, second} =
      Aikido.Durable.ensure_started(durable, "thread-history",
        agent: AikidoTest.DurableTest.ThreadAgent
      )

    assert {:ok, ^thread} = Aikido.AgentServer.state(second, &{:ok, &1.agent.state.thread})

    assert {:ok, %{entries: entries, rev: 2}} =
             Aikido.AgentServer.call(
               second,
               Aikido.Signal.new!("aikido.thread.append", %{
                 entry: %{kind: :message, payload: %{text: "Continue after restoration"}}
               }),
               &{:ok, &1.agent.state.thread}
             )

    assert length(entries) == 2
  end

  test "dynamic cron definitions restore and cancellation persists", %{durable: durable} do
    alias AikidoTest.Support.SchedulerIntegrationHarness

    opts = [agent: AikidoTest.Support.SchedulerIntegrationHarness.CronAgent]
    {:ok, first} = Aikido.Durable.ensure_started(durable, "scheduled", opts)
    :ok = SchedulerIntegrationHarness.register_cron(first, "0 0 0 1 1 *", job_id: :annual)
    old_job = SchedulerIntegrationHarness.wait_for_job(first, :annual)

    {key, _} =
      Enum.find(DurableServer.Supervisor.global_members(durable), fn {_, {pid, _}} ->
        pid == first
      end)

    assert {:ok, info} = DurableServer.Supervisor.get_server_info(durable, key)
    saved = Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state)
    assert Map.has_key?(saved.cron_specs, :annual)

    redumped =
      saved
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(1, &1))

    assert saved == redumped

    :ok = Aikido.Durable.stop(durable, "scheduled")
    {:ok, second} = Aikido.Durable.ensure_started(durable, "scheduled", opts)
    new_job = SchedulerIntegrationHarness.wait_for_job(second, :annual)
    refute old_job == new_job
    refute Process.alive?(old_job)

    :ok = SchedulerIntegrationHarness.cancel_cron(second, :annual)

    AikidoTest.AgentWait.await_state_value(second, fn state ->
      !Map.has_key?(state.cron_specs, :annual)
    end)

    :ok = Aikido.Durable.stop(durable, "scheduled")
    {:ok, third} = Aikido.Durable.ensure_started(durable, "scheduled", opts)
    assert :ok = Aikido.AgentServer.await_ready(third)

    assert {:ok, {%{}, %{}}} =
             Aikido.AgentServer.state(third, &{:ok, {&1.cron_jobs, &1.cron_specs}})
  end

  test("agent and slice codecs compose with custom checkpoint/restore", %{durable: durable}) do
    {:ok, first} =
      Aikido.Durable.ensure_started(durable, "codec", agent: AikidoTest.DurableTest.CodecAgent)

    {key, _} =
      Enum.find(DurableServer.Supervisor.global_members(durable), fn {_key, {pid, _}} ->
        pid == first
      end)

    assert {:ok, info} = DurableServer.Supervisor.get_server_info(durable, key)
    snapshot = Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state)

    assert {:checkpoint, %{custom_state: %{domain: %{encoded: "5"}, codec: %{encoded: "3"}}}} =
             snapshot.agent

    assert :ok = Aikido.Durable.stop(durable, "codec")

    {:ok, restored} =
      Aikido.Durable.ensure_started(durable, "codec", agent: AikidoTest.DurableTest.CodecAgent)

    assert {:ok, %{domain: %{value: 5}, codec: %{value: 3}}} =
             Aikido.AgentServer.state(restored, &{:ok, &1.agent.state})
  end

  test "initial and live snapshots both apply codecs to the only copy of startup state", %{
    durable: durable
  } do
    module = AikidoTest.DurableTest.CodecAgent

    options = [
      agent_module: module,
      id: "safe",
      initial_state: %{domain: %{value: 7, credential: "private-marker"}}
    ]

    dumped = Aikido.Durable.AgentServer.dump_state(%{options: options, permanent: true})
    saved = Aikido.Durable.AgentServer.load_state(1, dumped)
    refute inspect(saved) =~ "private-marker"
    refute Keyword.has_key?(saved.options, :initial_state)
    assert {:checkpoint, %{custom_state: %{domain: %{encoded: "7"}}}} = saved.agent

    redumped =
      saved
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(1, &1))

    assert saved == redumped

    {:ok, pid} =
      Aikido.Durable.ensure_started(durable, "safe",
        agent: module,
        initial_state: %{domain: %{value: 7, credential: "private-marker"}}
      )

    {key, _} =
      Enum.find(DurableServer.Supervisor.global_members(durable), fn {_key, {member, _}} ->
        member == pid
      end)

    assert {:ok, info} = DurableServer.Supervisor.get_server_info(durable, key)
    saved = Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state)
    refute inspect(saved) =~ "private-marker"
    refute Keyword.has_key?(saved.options, :initial_state)

    redumped =
      saved
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(1, &1))

    assert saved == redumped
    assert :ok = Aikido.Durable.stop(durable, "safe")
    {:ok, restored} = Aikido.Durable.ensure_started(durable, "safe", agent: module)
    assert {:ok, 7} = Aikido.AgentServer.state(restored, &{:ok, &1.agent.state.domain.value})
  end

  test "initialization lock preserves the encoded state and logical parent before restore completes",
       %{durable: durable} do
    {:ok, parent} = Aikido.Durable.ensure_started(durable, "lock-parent")
    Process.register(self(), AikidoTest.DurableTest.InitObserver)

    activation =
      Task.async(fn ->
        Aikido.Durable.ensure_started(durable, "lock-child",
          agent: AikidoTest.DurableTest.CodecAgent,
          permanent: false,
          initial_state: %{domain: %{value: 91}},
          agent_opts: [
            parent: %{pid: parent, id: "lock-parent", tag: :child, partition: nil, meta: %{}}
          ]
        )
      end)

    assert_receive {:restoring_checkpoint, child}, 5_000
    on_exit(fn -> send(child, :resume_restore) end)

    storage_key =
      "agent/" <> Base.url_encode64(:erlang.term_to_binary({nil, "lock-child"}), padding: false)

    assert {:ok, info} = DurableServer.Supervisor.get_server_info(durable, storage_key)
    saved = Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state)
    assert {:checkpoint, %{custom_state: %{domain: %{encoded: "91"}}}} = saved.agent
    assert saved.parent == %{id: "lock-parent", tag: :child, partition: nil, meta: %{}}
    assert saved.initial?

    redumped =
      saved
      |> Aikido.Durable.AgentServer.dump_state()
      |> then(&Aikido.Durable.AgentServer.load_state(1, &1))

    assert saved == redumped
    send(child, :resume_restore)
    assert {:ok, ^child} = Task.await(activation)
    Process.unregister(AikidoTest.DurableTest.InitObserver)
    assert {:ok, 91} = Aikido.AgentServer.state(child, &{:ok, &1.agent.state.domain.value})
  end

  test("the default Aikido lifecycle uses DurableServer", %{directory: directory}) do
    instance = AikidoTest.DurableDefaultInstance

    start_supervised!(
      {Aikido, name: instance, durable: [data_dir: Path.join(directory, "default")]}
    )

    assert {:ok, pid} =
             AikidoTest.Case.start_test_agent(instance, AikidoTest.TestAgents.Counter,
               id: "default-counter"
             )

    assert %DurableServer{} = :sys.get_state(pid)
    assert AikidoTest.Case.agent_pid(instance, "default-counter") == pid
    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(instance), pid)
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

    first = AikidoTest.Case.agent_pid(instance, team.id)
    second = AikidoTest.LifecycleWait.restart(first)

    member =
      AikidoTest.AgentWait.await_state_value(
        second,
        fn state ->
          if state.agent.state.team.operation.status == :completed do
            state.agent.state.team.members["counter"]
          end
        end,
        timeout: 10_000
      )

    assert Process.alive?(member)
    assert {:ok, 8} = Aikido.AgentServer.state(member, &{:ok, &1.agent.state.state.count})
    assert :ok = Aikido.Durable.stop(Aikido.durable_supervisor_name(instance), second)

    resumed =
      snapshot_result(AikidoTest.AshFixtures.Domain.dynamic_start!(%{id: team.id, topology: %{}}))

    assert Map.has_key?(resumed.team.topology.nodes, "counter")
    resumed_pid = AikidoTest.Case.agent_pid(instance, team.id)

    worker =
      AikidoTest.AgentWait.await_state_value(
        resumed_pid,
        fn state ->
          if state.agent.state.team.operation.status == :completed do
            state.agent.state.team.members["counter"]
          end
        end,
        timeout: 10_000
      )

    assert Process.alive?(worker)
  end

  defp snapshot_result({:ok, %{resource: resource, id: id}}) do
    resource |> Ash.ActionInput.for_action(:inspect, %{agent: id}) |> Ash.run_action()
  end

  defp snapshot_result({:error, _} = error) do
    error
  end

  defp snapshot_result(%{resource: resource, id: id}) do
    resource |> Ash.ActionInput.for_action(:inspect, %{agent: id}) |> Ash.run_action!()
  end
end
