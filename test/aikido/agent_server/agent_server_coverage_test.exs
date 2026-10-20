defmodule AikidoTest.AgentServerCoverageTest.SimpleTestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "simple_test_agent"
    path :domain

    schema do
      attribute :counter, :integer do
        description "Counter used to observe routed state transitions."
        default 0
      end
    end

    route "increment", {AikidoTest.TestActions, :increment}
  end
end

defmodule AikidoTest.AgentServerCoverageTest do
  @moduledoc """
  AgentServer boundary coverage for process references, native initialization,
  call selectors, signal validation and scheduled delivery.
  """
  use AikidoTest.Case, async: true
  @moduletag :capture_log

  describe("resolve_server with {:via, ...}") do
    test("via tuple that resolves to nil returns error", %{aikido: aikido}) do
      start_supervised!({Registry, keys: :unique, name: Module.concat(aikido, ExternalRegistry)})

      nonexistent_via =
        {:via, Registry, {Module.concat(aikido, ExternalRegistry), "nonexistent-via-agent"}}

      signal = Aikido.Signal.new!("increment", %{}, source: "/test")

      assert {:error, :not_found} =
               Aikido.AgentServer.call(nonexistent_via, signal, fn s -> {:ok, s.agent} end)

      assert {:error, :not_found} = Aikido.AgentServer.cast(nonexistent_via, signal)

      assert {:error, :not_found} =
               Aikido.AgentServer.state(nonexistent_via, fn s -> {:ok, s.id} end)
    end

    test("via tuple that exists works", %{aikido: aikido}) do
      {:ok, _pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.TestAgents.Counter,
          id: "via-test-exists"
        )

      registry = Module.concat(aikido, ExternalRegistry)
      start_supervised!({Registry, keys: :unique, name: registry})
      pid = AikidoTest.Case.agent_pid(aikido, "via-test-exists")

      {:ok, :registered} =
        Aikido.AgentServer.state(pid, fn _ ->
          Registry.register(registry, "via-test-exists", nil)
          {:ok, :registered}
        end)

      via = {:via, Registry, {Module.concat(aikido, ExternalRegistry), "via-test-exists"}}
      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(via, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
    end
  end

  describe("resolve_server with string ID") do
    test("string ID returns error with helpful message", %{aikido: _aikido}) do
      signal = Aikido.Signal.new!("increment", %{}, source: "/test")

      assert {:error, {:invalid_server, message}} =
               Aikido.AgentServer.call("some-string-id", signal, fn s -> {:ok, s.agent} end)

      assert message =~ "String IDs require an explicit Aikido instance lookup"
      assert message =~ "some-string-id"
    end

    test("string ID error on cast", %{aikido: _aikido}) do
      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
      assert {:error, {:invalid_server, _}} = Aikido.AgentServer.cast("some-string-id", signal)
    end

    test("string ID error on state", %{aikido: _aikido}) do
      assert {:error, {:invalid_server, _}} =
               Aikido.AgentServer.state("some-string-id", fn s -> {:ok, s.id} end)
    end
  end

  describe("resolve_server with atom name") do
    test("atom name that doesn't exist returns error", %{aikido: _aikido}) do
      signal = Aikido.Signal.new!("increment", %{}, source: "/test")

      assert {:error, :not_found} =
               Aikido.AgentServer.call(:nonexistent_atom_server, signal, fn s ->
                 {:ok, s.agent}
               end)
    end
  end

  describe("agent resolution with defaults") do
    test("agent uses default values from schema", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServerCoverageTest.SimpleTestAgent
        )

      {:ok, counter} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)

      assert counter == 0
      GenServer.stop(pid)
    end

    test("id and initial_state options are respected", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServerCoverageTest.SimpleTestAgent,
          id: "custom-id-123",
          initial_state: %{counter: 999}
        )

      {:ok, %{id: id, counter: counter}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{id: s.id, counter: s.agent.state.domain.counter}}
        end)

      assert id == "custom-id-123"
      assert counter == 999
      GenServer.stop(pid)
    end
  end

  describe("module activation with initialized state") do
    test("uses explicit agent_module for action routing", %{aikido: aikido}) do
      agent = AikidoTest.TestAgents.Counter.initialize!(%{id: "prebuilt-struct-test"})
      agent = %{agent | state: put_in(agent.state, [:domain, :counter], 50)}

      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.TestAgents.Counter,
          id: agent.id,
          initial_state: agent.state
        )

      {:ok, %{id: id, counter: counter, agent_module: agent_module}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{id: s.id, counter: s.agent.state.domain.counter, agent_module: s.agent_module}}
        end)

      assert id == "prebuilt-struct-test"
      assert counter == 50
      assert agent_module == AikidoTest.TestAgents.Counter
      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
      {:ok, updated_agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert updated_agent.state.domain.counter == 51
      GenServer.stop(pid)
    end
  end

  describe("invalid signal handling") do
    test("signal with no matching route does not crash the agent", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.TestAgents.Minimal)

      signal = Aikido.Signal.new!("nonexistent_action", %{}, source: "/test")

      assert {:error, %Aikido.Error.RoutingError{}} =
               Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe("alive? with various server types") do
    test("alive? returns false for via tuple that doesn't exist", %{aikido: aikido}) do
      start_supervised!({Registry, keys: :unique, name: Module.concat(aikido, ExternalRegistry)})
      via = {:via, Registry, {Module.concat(aikido, ExternalRegistry), "nonexistent-alive-test"}}
      refute Aikido.AgentServer.alive?(via)
    end

    test("alive? returns false for atom name that doesn't exist", %{aikido: _aikido}) do
      refute Aikido.AgentServer.alive?(:nonexistent_atom_name)
    end

    test("alive? returns true for existing via tuple", %{aikido: aikido}) do
      {:ok, _pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.TestAgents.Counter,
          id: "alive-via-test"
        )

      registry = Module.concat(aikido, ExternalRegistry)
      start_supervised!({Registry, keys: :unique, name: registry})
      pid = AikidoTest.Case.agent_pid(aikido, "alive-via-test")

      {:ok, :registered} =
        Aikido.AgentServer.state(pid, fn _ ->
          Registry.register(registry, "alive-via-test", nil)
          {:ok, :registered}
        end)

      via = {:via, Registry, {Module.concat(aikido, ExternalRegistry), "alive-via-test"}}
      assert Aikido.AgentServer.alive?(via)
    end
  end
end
