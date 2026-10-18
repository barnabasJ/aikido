defmodule AikidoTest.InstanceTest.TestInstance do
  use Aikido, otp_app: :aikido_test_instance
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
      max_tasks: 500
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

    test "generates config/1 that reads from application env" do
      config = AikidoTest.InstanceTest.TestInstance.config()
      assert Keyword.get(config, :max_tasks) == 500
    end

    test "config/1 merges runtime overrides" do
      config = AikidoTest.InstanceTest.TestInstance.config(max_tasks: 1000, extra: :value)
      assert Keyword.get(config, :max_tasks) == 1000
      assert Keyword.get(config, :extra) == :value
    end

    test "child_spec/1 accepts runtime overrides" do
      spec = AikidoTest.InstanceTest.TestInstance.child_spec(max_tasks: 2000)
      assert {Aikido, :start_link, [opts]} = spec.start
      assert Keyword.get(opts, :max_tasks) == 2000
    end

    test "supports anonymous Redis command_fn in __aikido_storage__/0" do
      module = compile_inline_redis_instance("inline-storage")
      on_exit(fn -> unload_module(module) end)
      assert {Aikido.Storage.Redis, opts} = module.__aikido_storage__()
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

      assert :ok = module.hibernate(agent)

      assert {:ok, thawed} =
               module.thaw(AikidoTest.InstanceTest.RedisTestAgent, "redis-instance-agent")

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

      assert :ok = module.hibernate(unpartitioned)
      assert :ok = module.hibernate(partitioned, partition: :blue)

      assert {:ok, thawed_unpartitioned} =
               module.thaw(AikidoTest.InstanceTest.RedisTestAgent, "shared-partition-key")

      assert {:ok, thawed_partitioned} =
               module.thaw(AikidoTest.InstanceTest.RedisTestAgent, "shared-partition-key",
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
      task_sup = AikidoTest.InstanceTest.TestInstance.task_supervisor_name()
      assert Process.whereis(task_sup) != nil
    end

    test "starts Registry as child" do
      {:ok, _pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      reg = AikidoTest.InstanceTest.TestInstance.registry_name()
      assert Process.whereis(reg) != nil
    end

    test "starts RuntimeStore as child" do
      {:ok, _pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      runtime_store = AikidoTest.InstanceTest.TestInstance.runtime_store_name()
      assert Process.whereis(runtime_store) != nil
    end

    test "starts AgentSupervisor as child" do
      {:ok, _pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      agent_sup = AikidoTest.InstanceTest.TestInstance.agent_supervisor_name()
      assert Process.whereis(agent_sup) != nil
    end
  end

  describe("instance agent API") do
    test "start_agent/2 starts an agent" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, agent_pid} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "test-1"
        )

      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)
    end

    test "whereis/1 looks up an agent by ID" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, agent_pid} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "lookup-test"
        )

      found_pid = AikidoTest.InstanceTest.TestInstance.whereis("lookup-test")
      assert found_pid == agent_pid
    end

    test "whereis/1 returns nil for unknown ID" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      assert AikidoTest.InstanceTest.TestInstance.whereis("nonexistent") == nil
    end

    test "list_agents/0 lists all agents" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, _} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "list-1"
        )

      {:ok, _} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "list-2"
        )

      agents = AikidoTest.InstanceTest.TestInstance.list_agents()
      ids = Enum.map(agents, fn {id, _pid} -> id end)
      assert "list-1" in ids
      assert "list-2" in ids
    end

    test "agent_count/0 returns count of running agents" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()
      assert AikidoTest.InstanceTest.TestInstance.agent_count() == 0

      {:ok, _} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "count-1"
        )

      assert AikidoTest.InstanceTest.TestInstance.agent_count() == 1

      {:ok, _} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "count-2"
        )

      assert AikidoTest.InstanceTest.TestInstance.agent_count() == 2
    end

    test "stop_agent/1 stops an agent by ID" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, pid} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "stop-test"
        )

      assert AikidoTest.InstanceTest.TestInstance.whereis("stop-test") != nil
      ref = Process.monitor(pid)
      assert :ok = AikidoTest.InstanceTest.TestInstance.stop_agent("stop-test")
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
      eventually(fn -> AikidoTest.InstanceTest.TestInstance.whereis("stop-test") == nil end)
    end

    test "stop_agent/1 stops an agent by pid" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, pid} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "stop-pid-test"
        )

      assert Process.alive?(pid)
      assert :ok = AikidoTest.InstanceTest.TestInstance.stop_agent(pid)
      refute Process.alive?(pid)
    end

    test "partitions isolate same agent IDs within one instance" do
      {:ok, _sup_pid} = AikidoTest.InstanceTest.TestInstance.start_link()

      {:ok, unpartitioned_pid} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "shared-id"
        )

      {:ok, alpha_pid} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "shared-id",
          partition: :alpha
        )

      {:ok, beta_pid} =
        AikidoTest.InstanceTest.TestInstance.start_agent(AikidoTest.TestAgents.Minimal,
          id: "shared-id",
          partition: :beta
        )

      assert unpartitioned_pid != alpha_pid
      assert alpha_pid != beta_pid
      assert AikidoTest.InstanceTest.TestInstance.whereis("shared-id") == unpartitioned_pid

      assert AikidoTest.InstanceTest.TestInstance.whereis("shared-id", partition: :alpha) ==
               alpha_pid

      assert AikidoTest.InstanceTest.TestInstance.whereis("shared-id", partition: :beta) ==
               beta_pid

      assert AikidoTest.InstanceTest.TestInstance.list_agents() == [
               {"shared-id", unpartitioned_pid}
             ]

      assert AikidoTest.InstanceTest.TestInstance.list_agents(partition: :alpha) == [
               {"shared-id", alpha_pid}
             ]

      assert AikidoTest.InstanceTest.TestInstance.list_agents(partition: :beta) == [
               {"shared-id", beta_pid}
             ]

      assert AikidoTest.InstanceTest.TestInstance.agent_count() == 1
      assert AikidoTest.InstanceTest.TestInstance.agent_count(partition: :alpha) == 1
      assert AikidoTest.InstanceTest.TestInstance.agent_count(partition: :beta) == 1
      assert :ok = AikidoTest.InstanceTest.TestInstance.stop_agent("shared-id", partition: :alpha)

      eventually(fn ->
        AikidoTest.InstanceTest.TestInstance.whereis("shared-id", partition: :alpha) == nil
      end)

      assert AikidoTest.InstanceTest.TestInstance.whereis("shared-id") == unpartitioned_pid

      assert AikidoTest.InstanceTest.TestInstance.whereis("shared-id", partition: :beta) ==
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
