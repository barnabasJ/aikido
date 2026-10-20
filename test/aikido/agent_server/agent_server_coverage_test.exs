defmodule AikidoTest.AgentServerCoverageTest.SimpleTestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "simple_test_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
    end

    route "increment", {AikidoTest.TestActions, :increment}
  end
end

defmodule AikidoTest.AgentServerCoverageTest.ManyDirectivesAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    count =
      input.arguments.count

    directives =
      for i <- 1..count do
        signal =
          struct!(Jido.Signal,
            id: nil,
            type: "test.emitted.#{i}",
            data: %{index: i},
            source: "/test"
          )

        %Aikido.Directives.Emit{signal: signal}
      end

    Aikido.Types.ActionResult.new(state: %{directive_count: count}, directives: directives)
  end
end

defmodule AikidoTest.AgentServerCoverageTest.ManyDirectivesAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "many_directives_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
      attribute :directive_count, :integer, default: 0
    end

    route "many_directives",
          {AikidoTest.AgentServerCoverageTest.ManyDirectivesAgent, :many_directives}
  end

  actions do
    action :many_directives, Aikido.Types.ActionResult do
      argument :state, :term
      argument :count, :integer, default: 10
      run AikidoTest.AgentServerCoverageTest.ManyDirectivesAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServerCoverageTest.CompleteAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{status: :completed, last_answer: "done!"},
      directives: []
    )
  end
end

defmodule AikidoTest.AgentServerCoverageTest.FailAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{status: :failed, error: "something went wrong"},
      directives: []
    )
  end
end

defmodule AikidoTest.AgentServerCoverageTest.DelayCompleteAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    delay =
      input.arguments.delay_ms

    AikidoTest.TestActions.SlowAction.Implementation.work(delay)

    Aikido.Types.ActionResult.new(
      state: %{status: :completed, last_answer: "delayed done!"},
      directives: []
    )
  end
end

defmodule AikidoTest.AgentServerCoverageTest.CompletionAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "completion_agent"
    path :domain

    schema do
      attribute :status, :atom, default: :pending
      attribute :last_answer, :term, default: nil
      attribute :error, :term, default: nil
    end

    route "complete", {AikidoTest.AgentServerCoverageTest.CompletionAgent, :complete}
    route "fail", {AikidoTest.AgentServerCoverageTest.CompletionAgent, :fail}
    route "delay_complete", {AikidoTest.AgentServerCoverageTest.CompletionAgent, :delay_complete}
  end

  actions do
    action :complete, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.AgentServerCoverageTest.CompleteAction.Implementation
    end

    action :fail, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.AgentServerCoverageTest.FailAction.Implementation
    end

    action :delay_complete, Aikido.Types.ActionResult do
      argument :state, :term
      argument :delay_ms, :integer, default: 50
      run AikidoTest.AgentServerCoverageTest.DelayCompleteAction.Implementation
    end
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

      signal = Jido.Signal.new!("increment", %{}, source: "/test")

      assert {:error, :not_found} =
               Aikido.AgentServer.call(nonexistent_via, signal, fn s -> {:ok, s.agent} end)

      assert {:error, :not_found} = Aikido.AgentServer.cast(nonexistent_via, signal)

      assert {:error, :not_found} =
               Aikido.AgentServer.state(nonexistent_via, fn s -> {:ok, s.id} end)
    end

    test("via tuple that exists works", %{aikido: aikido}) do
      {:ok, _pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.TestAgents.Counter,
          id: "via-test-exists",
          aikido: aikido
        )

      registry = Module.concat(aikido, ExternalRegistry)
      start_supervised!({Registry, keys: :unique, name: registry})
      pid = Aikido.whereis(aikido, "via-test-exists")

      {:ok, :registered} =
        Aikido.AgentServer.state(pid, fn _ ->
          Registry.register(registry, "via-test-exists", nil)
          {:ok, :registered}
        end)

      via = {:via, Registry, {Module.concat(aikido, ExternalRegistry), "via-test-exists"}}
      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(via, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
    end
  end

  describe("resolve_server with string ID") do
    test("string ID returns error with helpful message", %{aikido: _aikido}) do
      signal = Jido.Signal.new!("increment", %{}, source: "/test")

      assert {:error, {:invalid_server, message}} =
               Aikido.AgentServer.call("some-string-id", signal, fn s -> {:ok, s.agent} end)

      assert message =~ "String IDs require an explicit Aikido instance lookup"
      assert message =~ "some-string-id"
    end

    test("string ID error on cast", %{aikido: _aikido}) do
      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      assert {:error, {:invalid_server, _}} = Aikido.AgentServer.cast("some-string-id", signal)
    end

    test("string ID error on state", %{aikido: _aikido}) do
      assert {:error, {:invalid_server, _}} =
               Aikido.AgentServer.state("some-string-id", fn s -> {:ok, s.id} end)
    end
  end

  describe("resolve_server with atom name") do
    test("atom name that doesn't exist returns error", %{aikido: _aikido}) do
      signal = Jido.Signal.new!("increment", %{}, source: "/test")

      assert {:error, :not_found} =
               Aikido.AgentServer.call(:nonexistent_atom_server, signal, fn s ->
                 {:ok, s.agent}
               end)
    end
  end

  describe("agent resolution with defaults") do
    test("agent uses default values from schema", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerCoverageTest.SimpleTestAgent,
          aikido: aikido
        )

      {:ok, counter} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)

      assert counter == 0
      GenServer.stop(pid)
    end

    test("id and initial_state options are respected", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerCoverageTest.SimpleTestAgent,
          id: "custom-id-123",
          initial_state: %{counter: 999},
          aikido: aikido
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

  describe("pre-built struct with agent_module option") do
    test("uses explicit agent_module for action routing", %{aikido: aikido}) do
      agent = AikidoTest.TestAgents.Counter.initialize!(%{id: "prebuilt-struct-test"})
      agent = %{agent | state: put_in(agent.state, [:domain, :counter], 50)}

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.TestAgents.Counter,
          id: agent.id,
          initial_state: agent.state,
          aikido: aikido
        )

      {:ok, %{id: id, counter: counter, agent_module: agent_module}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{id: s.id, counter: s.agent.state.domain.counter, agent_module: s.agent_module}}
        end)

      assert id == "prebuilt-struct-test"
      assert counter == 50
      assert agent_module == AikidoTest.TestAgents.Counter
      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      {:ok, updated_agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert updated_agent.state.domain.counter == 51
      GenServer.stop(pid)
    end
  end

  describe("invalid signal handling") do
    test("signal with no matching route does not crash the agent", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(agent_module: AikidoTest.TestAgents.Minimal, aikido: aikido)

      signal = Jido.Signal.new!("nonexistent_action", %{}, source: "/test")

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
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.TestAgents.Counter,
          id: "alive-via-test",
          aikido: aikido
        )

      registry = Module.concat(aikido, ExternalRegistry)
      start_supervised!({Registry, keys: :unique, name: registry})
      pid = Aikido.whereis(aikido, "alive-via-test")

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
