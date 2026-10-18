defmodule AikidoTest.AikidoTest do
  use AikidoTest.Case, async: true

  alias Aikido.AgentServer
  alias AikidoTest.TestAgents.Minimal

  describe "scheduler_name/1" do
    test "returns scheduler name for aikido instance" do
      assert Aikido.scheduler_name(MyApp.Aikido) == MyApp.Aikido.Scheduler
    end

    test "works with nested module names" do
      assert Aikido.scheduler_name(MyApp.Sub.Aikido) == MyApp.Sub.Aikido.Scheduler
    end
  end

  describe "agent_pool_name/2" do
    test "returns pool name for aikido instance and pool" do
      # Module.concat keeps the atom as-is (lowercase) when joining
      result = Aikido.agent_pool_name(MyApp.Aikido, :workers)
      assert result == :"Elixir.MyApp.Aikido.AgentPool.workers"
    end

    test "works with different pool names" do
      result = Aikido.agent_pool_name(MyApp.Aikido, :processors)
      assert result == :"Elixir.MyApp.Aikido.AgentPool.processors"
    end

    test "works with nested module names" do
      result = Aikido.agent_pool_name(MyApp.Sub.Aikido, :pool)
      assert result == :"Elixir.MyApp.Sub.Aikido.AgentPool.pool"
    end
  end

  describe "generate_id/0" do
    test "generates a unique identifier" do
      id1 = Aikido.generate_id()
      id2 = Aikido.generate_id()

      assert is_binary(id1)
      assert is_binary(id2)
      assert id1 != id2
    end
  end

  describe "stop_agent/2 with non-existent id" do
    test "returns error when agent not found", %{aikido: aikido} do
      assert {:error, :not_found} = Aikido.stop_agent(aikido, "non-existent-agent-id")
    end
  end

  describe "parent_binding/3" do
    test "returns :error when no parent binding exists", %{aikido: aikido} do
      assert :error = Aikido.parent_binding(aikido, "missing-child")
    end

    test "returns the persisted binding for an adopted child", %{aikido: aikido} do
      {:ok, parent_pid} =
        AgentServer.start(agent_module: Minimal, id: "parent-binding-parent", aikido: aikido)

      {:ok, child_pid} =
        AgentServer.start(agent_module: Minimal, id: "parent-binding-child", aikido: aikido)

      assert {:ok, ^child_pid} = AgentServer.adopt_child(parent_pid, child_pid, :worker)

      assert {:ok, binding} = Aikido.parent_binding(aikido, "parent-binding-child")
      assert binding.parent_id == "parent-binding-parent"
      assert binding.parent_partition == nil
      assert binding.tag == :worker
      assert binding.meta == %{}
    end

    test "respects partitioned bindings", %{aikido: aikido} do
      {:ok, parent_pid} =
        AgentServer.start(
          agent_module: Minimal,
          id: "partitioned-parent",
          aikido: aikido,
          partition: :alpha
        )

      {:ok, alpha_child_pid} =
        AgentServer.start(
          agent_module: Minimal,
          id: "shared-child",
          aikido: aikido,
          partition: :alpha
        )

      {:ok, _beta_child_pid} =
        AgentServer.start(
          agent_module: Minimal,
          id: "shared-child",
          aikido: aikido,
          partition: :beta
        )

      assert {:ok, ^alpha_child_pid} =
               AgentServer.adopt_child(parent_pid, alpha_child_pid, :worker)

      assert {:ok, binding} = Aikido.parent_binding(aikido, "shared-child", partition: :alpha)
      assert binding.parent_id == "partitioned-parent"
      assert binding.parent_partition == :alpha
      assert binding.tag == :worker

      assert :error = Aikido.parent_binding(aikido, "shared-child", partition: :beta)
      assert :error = Aikido.parent_binding(aikido, "shared-child")
    end
  end

  describe "discovery delegates" do
    test "list_actions/1 delegates to Aikido.Discovery" do
      actions = Aikido.list_actions()
      assert is_list(actions)
    end

    test "list_sensors/1 delegates to Aikido.Discovery" do
      sensors = Aikido.list_sensors()
      assert is_list(sensors)
    end

    test "list_slices/1 delegates to Aikido.Discovery" do
      slices = Aikido.list_slices()
      assert is_list(slices)
    end

    test "list_demos/1 delegates to Aikido.Discovery" do
      demos = Aikido.list_demos()
      assert is_list(demos)
    end

    test "get_action_by_slug/1 delegates to Aikido.Discovery" do
      result = Aikido.get_action_by_slug("nonexistent-action-slug")
      assert result == nil or is_map(result)
    end

    test "get_sensor_by_slug/1 delegates to Aikido.Discovery" do
      result = Aikido.get_sensor_by_slug("nonexistent-sensor-slug")
      assert result == nil or is_map(result)
    end

    test "get_slice_by_slug/1 delegates to Aikido.Discovery" do
      result = Aikido.get_slice_by_slug("nonexistent-slice-slug")
      assert result == nil or is_map(result)
    end

    test "refresh_discovery/0 delegates to Aikido.Discovery" do
      result = Aikido.refresh_discovery()
      assert result == :ok
    end
  end

  describe "AgentServer.await_child/3" do
    test "returns timeout when child not found", %{aikido: aikido} do
      {:ok, pid} = Aikido.start_agent(aikido, Minimal, id: "await-child-delegate")

      result = Aikido.AgentServer.await_child(pid, :nonexistent, timeout: 50)
      assert {:error, :timeout} = result
    end
  end
end
