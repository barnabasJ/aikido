defmodule AikidoTest.AgentServerCoverageTest.SimpleTestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "simple_test_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
    end
  end

  signal_routes do
    route "increment", AikidoTest.TestActions.IncrementAction
  end
end

defmodule AikidoTest.AgentServerCoverageTest.ManyDirectivesAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    count =
      case Map.fetch(input.arguments, :count) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:count]
      end

    directives =
      for i <- 1..count do
        signal = Jido.Signal.new!("test.emitted.#{i}", %{index: i}, source: "/test")
        %Aikido.Directives.Emit{signal: signal}
      end

    Aikido.ActionResult.new(state: %{directive_count: count}, directives: directives)
  end
end

defmodule AikidoTest.AgentServerCoverageTest.ManyDirectivesAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :many_directives, Aikido.ActionResult do
      argument :state, :term
      argument :count, :integer, default: 10
      run {AikidoTest.AgentServerCoverageTest.ManyDirectivesAction.Implementation, action: :run}
    end
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
  end

  signal_routes do
    route "many_directives", AikidoTest.AgentServerCoverageTest.ManyDirectivesAction
  end
end

defmodule AikidoTest.AgentServerCoverageTest.CompleteAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    Aikido.ActionResult.new(state: %{status: :completed, last_answer: "done!"}, directives: [])
  end
end

defmodule AikidoTest.AgentServerCoverageTest.CompleteAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :complete, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServerCoverageTest.CompleteAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AgentServerCoverageTest.FailAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    Aikido.ActionResult.new(
      state: %{status: :failed, error: "something went wrong"},
      directives: []
    )
  end
end

defmodule AikidoTest.AgentServerCoverageTest.FailAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :fail, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServerCoverageTest.FailAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AgentServerCoverageTest.DelayCompleteAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    delay =
      case Map.fetch(input.arguments, :delay_ms) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:delay_ms]
      end

    Process.sleep(delay)

    Aikido.ActionResult.new(
      state: %{status: :completed, last_answer: "delayed done!"},
      directives: []
    )
  end
end

defmodule AikidoTest.AgentServerCoverageTest.DelayCompleteAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :delay_complete, Aikido.ActionResult do
      argument :state, :term
      argument :delay_ms, :integer, default: 50
      run {AikidoTest.AgentServerCoverageTest.DelayCompleteAction.Implementation, action: :run}
    end
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
  end

  signal_routes do
    route "complete", AikidoTest.AgentServerCoverageTest.CompleteAction
    route "fail", AikidoTest.AgentServerCoverageTest.FailAction
    route "delay_complete", AikidoTest.AgentServerCoverageTest.DelayCompleteAction
  end
end

defmodule AikidoTest.AgentServerCoverageTest do
  @moduledoc """
  Additional tests to improve AgentServer coverage.

  Tests uncovered paths including:
  - resolve_server with {:via, ...} that returns nil
  - Agent resolution with new/0 vs new/1
  - Pre-built struct with agent_module option
  - Lifecycle hooks (on_before_cmd, on_after_cmd)
  - Queue overflow scenario
  - Multiple await_completion waiters
  - Invalid signal handling
  """
  use AikidoTest.Case, async: true
  @moduletag :capture_log

  describe("resolve_server with {:via, ...}") do
    test("via tuple that resolves to nil returns error", %{aikido: aikido}) do
      nonexistent_via = {:via, Registry, {Aikido.registry_name(aikido), "nonexistent-via-agent"}}
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

      via = {:via, Registry, {Aikido.registry_name(aikido), "via-test-exists"}}
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

      assert message =~ "String IDs require explicit registry lookup"
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
    test("uses explicit agent_module for cmd routing", %{aikido: aikido}) do
      agent = AikidoTest.TestAgents.Counter.new(id: "prebuilt-struct-test")
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
      via = {:via, Registry, {Aikido.registry_name(aikido), "nonexistent-alive-test"}}
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

      via = {:via, Registry, {Aikido.registry_name(aikido), "alive-via-test"}}
      assert Aikido.AgentServer.alive?(via)
    end
  end
end
