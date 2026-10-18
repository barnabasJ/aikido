defmodule AikidoTest.AgentPoolTest do
  use ExUnit.Case, async: true
  import AikidoTest.Eventually
  @moduletag :capture_log
  alias Aikido.Agent.WorkerPool, as: AgentPool
  alias Aikido.AgentServer
  alias Jido.Signal
  alias AikidoTest.TestActions

  defmodule GetCountAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "get_count"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(_signal, slice, _opts, _ctx) do
      {:ok, Map.put(slice, :last_count, Map.get(slice, :counter, 0)), []}
    end
  end

  defmodule PoolTestAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("pool_test_agent")
      path(:domain)

      schema do
        attribute(:counter, :integer, default: 0)
        attribute(:last_count, :integer, default: 0)
      end
    end

    signal_routes do
      route("increment", TestActions.IncrementAction)
      route("get_count", GetCountAction)
    end
  end

  defp unique_aikido_name do
    :"aikido_pool_test_#{System.unique_integer([:positive])}"
  end

  describe("pool configuration") do
    test "starts pool with Aikido instance" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(
          name: aikido_name,
          agent_pools: [{:test_pool, PoolTestAgent, size: 2, max_overflow: 0}]
        )

      pool_name = Aikido.agent_pool_name(aikido_name, :test_pool)
      assert Process.whereis(pool_name) != nil
      Supervisor.stop(aikido_pid)
    end

    test "multiple pools can be configured" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(
          name: aikido_name,
          agent_pools: [{:pool_a, PoolTestAgent, size: 2}, {:pool_b, PoolTestAgent, size: 3}]
        )

      assert Process.whereis(Aikido.agent_pool_name(aikido_name, :pool_a)) != nil
      assert Process.whereis(Aikido.agent_pool_name(aikido_name, :pool_b)) != nil
      Supervisor.stop(aikido_pid)
    end
  end

  describe("with_agent/4") do
    test "executes function with pooled agent" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(name: aikido_name, agent_pools: [{:test_pool, PoolTestAgent, size: 2}])

      result =
        AgentPool.with_agent(aikido_name, :test_pool, fn pid ->
          assert is_pid(pid)
          :worked
        end)

      assert result == :worked
      Supervisor.stop(aikido_pid)
    end

    test "can call agent within transaction" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(name: aikido_name, agent_pools: [{:test_pool, PoolTestAgent, size: 2}])

      signal = Signal.new!("increment", %{}, source: "/test")

      result =
        AgentPool.with_agent(aikido_name, :test_pool, fn pid ->
          {:ok, agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
          agent.state.domain.counter
        end)

      assert result == 1
      Supervisor.stop(aikido_pid)
    end

    test "agent state persists across calls" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(name: aikido_name, agent_pools: [{:test_pool, PoolTestAgent, size: 1}])

      signal = Signal.new!("increment", %{}, source: "/test")

      AgentPool.with_agent(aikido_name, :test_pool, fn pid ->
        AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      end)

      result =
        AgentPool.with_agent(aikido_name, :test_pool, fn pid ->
          {:ok, agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
          agent.state.domain.counter
        end)

      assert result == 2
      Supervisor.stop(aikido_pid)
    end
  end

  describe("call/5") do
    test "sends signal to pooled agent" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(name: aikido_name, agent_pools: [{:test_pool, PoolTestAgent, size: 2}])

      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = AgentPool.call(aikido_name, :test_pool, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      Supervisor.stop(aikido_pid)
    end
  end

  describe("cast/4") do
    test "sends async signal to pooled agent" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(name: aikido_name, agent_pools: [{:test_pool, PoolTestAgent, size: 1}])

      signal = Signal.new!("increment", %{}, source: "/test")
      assert :ok = AgentPool.cast(aikido_name, :test_pool, signal)
      get_signal = Signal.new!("get_count", %{}, source: "/test")

      eventually(fn ->
        {:ok, agent} =
          AgentPool.call(aikido_name, :test_pool, get_signal, fn s -> {:ok, s.agent} end)

        agent.state.domain.counter >= 1
      end)

      Supervisor.stop(aikido_pid)
    end
  end

  describe("status/2") do
    test "returns pool status" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(
          name: aikido_name,
          agent_pools: [{:test_pool, PoolTestAgent, size: 3, max_overflow: 2}]
        )

      status = AgentPool.status(aikido_name, :test_pool)
      assert status.state == :ready
      assert status.overflow == 0
      assert status.available == 3
      assert status.checked_out == 0
      Supervisor.stop(aikido_pid)
    end

    test "shows checked out workers" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(name: aikido_name, agent_pools: [{:test_pool, PoolTestAgent, size: 3}])

      pid = AgentPool.checkout(aikido_name, :test_pool)
      status = AgentPool.status(aikido_name, :test_pool)
      assert status.checked_out == 1
      AgentPool.checkin(aikido_name, :test_pool, pid)
      status = AgentPool.status(aikido_name, :test_pool)
      assert status.checked_out == 0
      Supervisor.stop(aikido_pid)
    end
  end

  describe("checkout/3 and checkin/3") do
    test "manual checkout and checkin" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(name: aikido_name, agent_pools: [{:test_pool, PoolTestAgent, size: 2}])

      pid = AgentPool.checkout(aikido_name, :test_pool)
      assert is_pid(pid)
      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert :ok = AgentPool.checkin(aikido_name, :test_pool, pid)
      Supervisor.stop(aikido_pid)
    end
  end

  describe("worker_opts") do
    test "passes worker_opts to agent server" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(
          name: aikido_name,
          agent_pools: [
            {:test_pool, PoolTestAgent, size: 1, worker_opts: [initial_state: %{counter: 100}]}
          ]
        )

      get_signal = Signal.new!("get_count", %{}, source: "/test")

      {:ok, agent} =
        AgentPool.call(aikido_name, :test_pool, get_signal, fn s -> {:ok, s.agent} end)

      assert agent.state.domain.counter == 100
      Supervisor.stop(aikido_pid)
    end
  end

  describe("concurrent access") do
    test "handles concurrent requests" do
      aikido_name = unique_aikido_name()

      {:ok, aikido_pid} =
        Aikido.start_link(name: aikido_name, agent_pools: [{:test_pool, PoolTestAgent, size: 4}])

      signal = Signal.new!("increment", %{}, source: "/test")

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            AgentPool.call(aikido_name, :test_pool, signal, fn s -> {:ok, s.agent} end)
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, fn {:ok, _agent} -> true end)
      Supervisor.stop(aikido_pid)
    end
  end
end
