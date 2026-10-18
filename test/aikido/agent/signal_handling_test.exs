defmodule AikidoTest.Agent.SignalHandlingTest.EmitTestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    signal = Jido.Signal.new!("test.emitted", %{from: "agent"}, source: "/test")
    Aikido.ActionResult.new(state: %{}, directives: [%Aikido.Directives.Emit{signal: signal}])
  end
end

defmodule AikidoTest.Agent.SignalHandlingTest.EmitTestAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :emit_test, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.Agent.SignalHandlingTest.EmitTestAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "action_based_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
      attribute :messages, {:array, :term}, default: []
    end
  end

  signal_routes do
    route "increment", AikidoTest.TestActions.IncrementAction
    route "decrement", AikidoTest.TestActions.DecrementAction
    route "record", AikidoTest.TestActions.RecordAction
    route "emit_test", AikidoTest.Agent.SignalHandlingTest.EmitTestAction
  end
end

defmodule AikidoTest.Agent.SignalHandlingTest.PreProcessingAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "pre_processing_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
      attribute :last_action_type, :string, default: nil
    end
  end

  signal_routes do
    route "increment", AikidoTest.TestActions.IncrementAction
    route "decrement", AikidoTest.TestActions.DecrementAction
  end

  def on_before_cmd(agent, {action_mod, _params} = action) when is_atom(action_mod) do
    action_name = action_mod.__action_metadata__().name
    agent = %{agent | state: put_in(agent.state, [:domain, :last_action_type], action_name)}
    {:ok, agent, action}
  end

  def on_before_cmd(agent, action) do
    {:ok, agent, action}
  end
end

defmodule AikidoTest.Agent.SignalHandlingTest do
  @moduledoc """
  Tests signal routing through AgentServer.

  Signal handling architecture:
  1. Signals arrive at AgentServer
  2. AgentServer routes signals to actions via strategy.signal_routes or default mapping
  3. Actions are executed via Agent.cmd/2
  4. on_before_cmd/2 can intercept actions for pre-processing
  """
  use AikidoTest.Case, async: true

  describe("signal routing via AgentServer") do
    test("signals are routed to actions by type", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
          id: "signal-route-test",
          aikido: aikido
        )

      signal = Jido.Signal.new!("increment", %{amount: 5}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 5
      GenServer.stop(pid)
    end

    test("multiple signals processed in sequence", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
          id: "multi-signal-test",
          aikido: aikido
        )

      signals = [
        Jido.Signal.new!("increment", %{amount: 1}, source: "/test"),
        Jido.Signal.new!("increment", %{amount: 2}, source: "/test"),
        Jido.Signal.new!("increment", %{amount: 3}, source: "/test")
      ]

      final_agent =
        Enum.reduce(signals, nil, fn signal, _acc ->
          {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
          agent
        end)

      assert final_agent.state.domain.counter == 6
      GenServer.stop(pid)
    end

    test("signal data is passed to action", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
          id: "signal-data-test",
          aikido: aikido
        )

      signal = Jido.Signal.new!("record", %{message: "hello"}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.messages == ["hello"]
      GenServer.stop(pid)
    end

    test("action can return directives", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
          id: "directive-test",
          aikido: aikido
        )

      signal = Jido.Signal.new!("emit_test", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      GenServer.stop(pid)
    end

    test("unknown signal type short-circuits with {:error, _} but does not crash", %{
      aikido: aikido
    }) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
          id: "unknown-signal-test",
          aikido: aikido
        )

      signal = Jido.Signal.new!("unknown_action", %{}, source: "/test")

      assert {:error, %Aikido.Error.RoutingError{}} =
               Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      signal2 = Jido.Signal.new!("increment", %{amount: 1}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal2, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end
  end

  describe("direct cmd/2 usage") do
    test "cmd/2 works directly with action module tuples" do
      agent = AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent.new()

      {:ok, updated, _directives} =
        AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent.cmd(
          agent,
          {AikidoTest.TestActions.IncrementAction, %{amount: 5}}
        )

      assert updated.state.domain.counter == 5
    end
  end
end
