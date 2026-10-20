defmodule AikidoTest.InstanceTest.TestInstance do
  use Aikido, otp_app: :aikido_test_instance
end

defmodule AikidoTest.InstanceTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:aikido_test_instance, AikidoTest.InstanceTest.TestInstance,
      max_tasks: 500,
      durable: AikidoTest.Case.durable_options()
    )

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

      assert Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "stop-test") == nil
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

      assert Aikido.whereis(AikidoTest.InstanceTest.TestInstance, "shared-id", partition: :alpha) ==
               nil

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
