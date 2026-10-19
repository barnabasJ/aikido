defmodule AikidoTest.InstanceTest.TestInstance do
  use Aikido, otp_app: :aikido_test_instance
end

defmodule AikidoTest.InstanceTest.OverrideInstance do
  use Aikido, otp_app: :aikido_test_instance, default_slices: %{thread: false}
end

defmodule AikidoTest.InstanceTest.RedisTestAgent do
  use Aikido.Agent

  agent do
    name "redis_test_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
    end
  end
end

defmodule AikidoTest.InstanceTest.RedisMock do
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def command(command) do
    Agent.get_and_update(__MODULE__, fn state ->
      case command do
        ["GET", key] ->
          {{:ok, Map.get(state, key)}, state}

        ["SET", key, value] ->
          {{:ok, "OK"}, Map.put(state, key, value)}

        ["SET", key, value, "PX", _ttl] ->
          {{:ok, "OK"}, Map.put(state, key, value)}

        ["DEL" | keys] ->
          deleted = Enum.count(keys, &Map.has_key?(state, &1))
          {{:ok, deleted}, Map.drop(state, keys)}

        _ ->
          {{:ok, {:echo, command}}, state}
      end
    end)
  end
end

defmodule AikidoTest.InstanceTest do
  use ExUnit.Case, async: false
  import AikidoTest.Eventually

  defp compile_inline_redis_instance(prefix) do
    module =
      Module.concat(__MODULE__, :"InlineRedisInstance#{System.unique_integer([:positive])}")

    source = "defmodule #{inspect(module)} do
  use Aikido,
    otp_app: :aikido_test_instance,
    storage: {Aikido.Storage.Redis, [
      command_fn: &AikidoTest.InstanceTest.RedisMock.command/1,
      prefix: #{inspect(prefix)}
    ]}
end
"
    Code.compile_string(source)
    module
  end

  defp unload_module(module) do
    :code.purge(module)
    :code.delete(module)
  end

  setup do
    Application.put_env(:aikido_test_instance, AikidoTest.InstanceTest.TestInstance,
      max_tasks: 500,
      durable: AikidoTest.Case.durable_options()
    )

    {:ok, _pid} = start_supervised({AikidoTest.InstanceTest.RedisMock, []})

    on_exit(fn ->
      Application.delete_env(:aikido_test_instance, AikidoTest.InstanceTest.TestInstance)

      if pid = Process.whereis(AikidoTest.InstanceTest.TestInstance) do
        try do
          Supervisor.stop(pid, :normal, 5000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  describe("instance module definition") do
    test "generates child_spec/1" do
      spec = AikidoTest.InstanceTest.TestInstance.child_spec([])
      assert spec.id == AikidoTest.InstanceTest.TestInstance
      assert spec.type == :supervisor
      assert {Aikido, :start_link, [opts]} = spec.start
      assert Keyword.get(opts, :name) == AikidoTest.InstanceTest.TestInstance
    end

    test "shared config reads from application env" do
      config = Aikido.config(AikidoTest.InstanceTest.TestInstance)
      assert Keyword.get(config, :max_tasks) == 500
    end

    test "shared config merges runtime overrides" do
      config = Aikido.config(AikidoTest.InstanceTest.TestInstance, max_tasks: 1000, extra: :value)
      assert Keyword.get(config, :max_tasks) == 1000
      assert Keyword.get(config, :extra) == :value
    end

    test "child_spec/1 accepts runtime overrides" do
      spec = AikidoTest.InstanceTest.TestInstance.child_spec(max_tasks: 2000)
      assert {Aikido, :start_link, [opts]} = spec.start
      assert Keyword.get(opts, :max_tasks) == 2000
    end

    test "shared config respects explicit supervisor names" do
      config = Aikido.config(AikidoTest.InstanceTest.TestInstance, name: :custom_runtime)
      assert config[:name] == :custom_runtime
      assert config[:otp_app] == :aikido_test_instance
    end

    test "observability reads a named instance's application configuration" do
      instance = AikidoTest.InstanceTest.TestInstance
      config = Application.get_env(:aikido_test_instance, instance)

      Application.put_env(
        :aikido_test_instance,
        instance,
        Keyword.merge(config,
          telemetry: [log_level: :warning],
          observability: [log_level: :debug]
        )
      )

      assert Aikido.Observe.Config.telemetry_log_level(instance) == :warning
      assert Aikido.Observe.Config.observe_log_level(instance) == :debug
    end

    test "default slice resolution applies DSL overrides to application defaults" do
      instance = AikidoTest.InstanceTest.OverrideInstance

      Application.put_env(:aikido_test_instance, instance,
        default_slices: [thread: Aikido.Slices.Thread, memory: Aikido.Slices.Memory]
      )

      on_exit(fn -> Application.delete_env(:aikido_test_instance, instance) end)

      assert Aikido.Agent.DefaultSlices.for_instance(instance) == [memory: Aikido.Slices.Memory]
    end

    test "Spark Info preserves Redis command function captures" do
      module = compile_inline_redis_instance("inline-storage")
      on_exit(fn -> unload_module(module) end)

      assert {Aikido.Storage.Redis, opts} =
               Aikido.Dsl.Instance.Info.instance_options(module).storage

      assert is_function(opts[:command_fn], 1)
      assert {:ok, {:echo, ["PING"]}} = opts[:command_fn].(["PING"])
      assert opts[:prefix] == "inline-storage"
    end

    test "hibernate and thaw work through a dynamically compiled Redis instance" do
      module = compile_inline_redis_instance("inline-persist")
      on_exit(fn -> unload_module(module) end)

      agent =
        AikidoTest.InstanceTest.RedisTestAgent.new(id: "redis-instance-agent")
        |> then(fn agent ->
          %{agent | state: %{agent.state | domain: %{agent.state.domain | counter: 42}}}
        end)
        |> then(fn agent ->
          thread =
            Aikido.Slices.Thread.new(id: "redis-thread")
            |> Aikido.Slices.Thread.append(%{kind: :note, payload: %{text: "saved"}})

          %{agent | state: Map.put(agent.state, :thread, thread)}
        end)

      assert :ok = Aikido.hibernate(module, agent)

      assert {:ok, thawed} =
               Aikido.thaw(module, AikidoTest.InstanceTest.RedisTestAgent, "redis-instance-agent")

      assert thawed.state.domain.counter == 42
      assert thawed.state[:thread].id == "redis-thread"
      assert Aikido.Slices.Thread.entry_count(thawed.state[:thread]) == 1
    end

    test "partitioned and unpartitioned checkpoints coexist through an instance module" do
      module = compile_inline_redis_instance("inline-partition-persist")
      on_exit(fn -> unload_module(module) end)

      unpartitioned =
        AikidoTest.InstanceTest.RedisTestAgent.new(id: "shared-partition-key")
        |> then(fn agent ->
          %{agent | state: %{agent.state | domain: %{agent.state.domain | counter: 10}}}
        end)

      partitioned =
        AikidoTest.InstanceTest.RedisTestAgent.new(id: "shared-partition-key")
        |> then(fn agent ->
          %{
            agent
            | state:
                agent.state |> put_in([:domain, :counter], 20) |> Map.put(:__partition__, :blue)
          }
        end)

      assert :ok = Aikido.hibernate(module, unpartitioned)
      assert :ok = Aikido.hibernate(module, partitioned, partition: :blue)

      assert {:ok, thawed_unpartitioned} =
               Aikido.thaw(module, AikidoTest.InstanceTest.RedisTestAgent, "shared-partition-key")

      assert {:ok, thawed_partitioned} =
               Aikido.thaw(module, AikidoTest.InstanceTest.RedisTestAgent, "shared-partition-key",
                 partition: :blue
               )

      assert thawed_unpartitioned.state.domain.counter == 10
      assert Map.get(thawed_unpartitioned.state, :__partition__) == nil
      assert thawed_partitioned.state.domain.counter == 20
      assert thawed_partitioned.state.__partition__ == :blue
    end
  end

  describe("instance lifecycle") do
    test "start_link/1 starts the supervisor" do
      {:ok, pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      assert is_pid(pid)
      assert Process.alive?(pid)
      assert Process.whereis(AikidoTest.InstanceTest.TestInstance) == pid
    end

    test "starts TaskSupervisor as child" do
      {:ok, _pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      task_sup = Aikido.task_supervisor_name(AikidoTest.InstanceTest.TestInstance)
      assert Process.whereis(task_sup) != nil
    end

    test "starts Registry as child" do
      {:ok, _pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      reg = Aikido.registry_name(AikidoTest.InstanceTest.TestInstance)
      assert Process.whereis(reg) != nil
    end

    test "starts the native DurableServer supervisor" do
      {:ok, _pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      agent_sup = Aikido.durable_supervisor_name(AikidoTest.InstanceTest.TestInstance)
      assert Process.whereis(agent_sup) != nil
    end
  end

  describe("shared runtime API with a named instance") do
    test "shared start_agent/3 starts an agent" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, agent_pid} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "test-1"
        )

      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)
    end

    test "shared whereis/2 looks up an agent by ID" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, agent_pid} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "lookup-test"
        )

      found_pid = Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "lookup-test")
      assert found_pid == agent_pid
    end

    test "shared whereis/2 returns nil for unknown ID" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      assert Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "nonexistent") == nil
    end

    test "shared list_agents/1 lists all agents" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, _} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "list-1"
        )

      {:ok, _} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "list-2"
        )

      agents = Aikido.list_agents(AikidoTest.InstanceTest.TestInstance)
      ids = Enum.map(agents, fn {id, _pid} -> id end)
      assert "list-1" in ids
      assert "list-2" in ids
    end

    test "shared agent_count/1 returns count of running agents" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      assert Aikido.agent_count(AikidoTest.InstanceTest.TestInstance) == 0

      {:ok, _} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "count-1"
        )

      assert Aikido.agent_count(AikidoTest.InstanceTest.TestInstance) == 1

      {:ok, _} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "count-2"
        )

      assert Aikido.agent_count(AikidoTest.InstanceTest.TestInstance) == 2
    end

    test "shared stop_agent/2 stops an agent by ID" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, pid} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "stop-test"
        )

      assert Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "stop-test") != nil
      ref = Process.monitor(pid)
      assert :ok = Aikido.stop_agent(AikidoTest.InstanceTest.TestInstance, "stop-test")
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

      eventually(fn ->
        Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "stop-test") == nil
      end)
    end

    test "shared stop_agent/2 stops an agent by pid" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, pid} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "stop-pid-test"
        )

      assert Process.alive?(pid)
      assert :ok = Aikido.stop_agent(AikidoTest.InstanceTest.TestInstance, pid)
      refute Process.alive?(pid)
    end

    test "partitions isolate same agent IDs within one instance" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, unpartitioned_pid} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "shared-id"
        )

      {:ok, alpha_pid} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "shared-id",
          partition: :alpha
        )

      {:ok, beta_pid} =
        Aikido.start_agent(AikidoTest.InstanceTest.TestInstance, AikidoTest.TestAgents.Minimal,
          id: "shared-id",
          partition: :beta
        )

      assert unpartitioned_pid != alpha_pid
      assert alpha_pid != beta_pid

      assert Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "shared-id") ==
               unpartitioned_pid

      assert Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "shared-id", partition: :alpha) ==
               alpha_pid

      assert Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "shared-id", partition: :beta) ==
               beta_pid

      assert Aikido.list_agents(AikidoTest.InstanceTest.TestInstance) == [
               {"shared-id", unpartitioned_pid}
             ]

      assert Aikido.list_agents(AikidoTest.InstanceTest.TestInstance, partition: :alpha) == [
               {"shared-id", alpha_pid}
             ]

      assert Aikido.list_agents(AikidoTest.InstanceTest.TestInstance, partition: :beta) == [
               {"shared-id", beta_pid}
             ]

      assert Aikido.agent_count(AikidoTest.InstanceTest.TestInstance) == 1
      assert Aikido.agent_count(AikidoTest.InstanceTest.TestInstance, partition: :alpha) == 1
      assert Aikido.agent_count(AikidoTest.InstanceTest.TestInstance, partition: :beta) == 1

      assert :ok =
               Aikido.stop_agent(AikidoTest.InstanceTest.TestInstance, "shared-id",
                 partition: :alpha
               )

      eventually(fn ->
        Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "shared-id", partition: :alpha) ==
          nil
      end)

      assert Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "shared-id") ==
               unpartitioned_pid

      assert Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "shared-id", partition: :beta) ==
               beta_pid
    end
  end

  describe("supervision tree integration") do
    test "can be used in Supervisor.start_link/2" do
      children = [AikidoTest.InstanceTest.TestInstance]
      {:ok, sup_pid} = Supervisor.start_link(children, strategy: :one_for_one)
      assert Process.alive?(sup_pid)
      assert Process.whereis(AikidoTest.InstanceTest.TestInstance) != nil
      Supervisor.stop(sup_pid, :normal, 5000)
    end

    test "can be used with runtime options in supervision tree" do
      children = [{AikidoTest.InstanceTest.TestInstance, [max_tasks: 3000]}]
      {:ok, sup_pid} = Supervisor.start_link(children, strategy: :one_for_one)
      assert Process.alive?(sup_pid)
      assert Process.whereis(AikidoTest.InstanceTest.TestInstance) != nil
      Supervisor.stop(sup_pid, :normal, 5000)
    end
  end
end
