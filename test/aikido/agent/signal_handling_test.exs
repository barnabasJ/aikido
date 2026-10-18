defmodule AikidoTest.Agent.SignalHandlingTest do
  @moduledoc "Tests signal routing through AgentServer.\n\nSignal handling architecture:\n1. Signals arrive at AgentServer\n2. AgentServer routes signals to actions via strategy.signal_routes or default mapping\n3. Actions are executed via Agent.cmd/2\n4. on_before_cmd/2 can intercept actions for pre-processing\n"
  use AikidoTest.Case, async: true
  alias Aikido.Directives
  alias Jido.Signal
  alias AikidoTest.TestActions

  defmodule EmitTestAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "emit_test"}}
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

    defp reduce(_signal, _slice, _opts, _ctx) do
      signal = Signal.new!("test.emitted", %{from: "agent"}, source: "/test")
      {:ok, %{}, [%Directives.Emit{signal: signal}]}
    end
  end

  # Agent with actions for signal routing
  defmodule ActionBasedAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("action_based_agent")
      path(:domain)

      schema do
        attribute(:counter, :integer, default: 0)
        attribute(:messages, {:array, :term}, default: [])
      end
    end

    signal_routes do
      route("increment", TestActions.IncrementAction)
      route("decrement", TestActions.DecrementAction)
      route("record", TestActions.RecordAction)
      route("emit_test", EmitTestAction)
    end
  end

  # Agent with on_before_cmd hook for pre-processing
  defmodule PreProcessingAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("pre_processing_agent")
      path(:domain)

      schema do
        attribute(:counter, :integer, default: 0)
        attribute(:last_action_type, :string, default: nil)
      end
    end

    signal_routes do
      route("increment", TestActions.IncrementAction)
      route("decrement", TestActions.DecrementAction)
    end

    # Intercept actions to capture the action type before processing
    # Handles action module tuples from signal routing
    def on_before_cmd(agent, {action_mod, _params} = action) when is_atom(action_mod) do
      action_name = action_mod.__action_metadata__().name
      agent = %{agent | state: put_in(agent.state, [:domain, :last_action_type], action_name)}
      {:ok, agent, action}
    end

    def on_before_cmd(agent, action) do
      {:ok, agent, action}
    end
  end

  describe("signal routing via AgentServer") do
    test("signals are routed to actions by type", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: ActionBasedAgent,
          id: "signal-route-test",
          aikido: aikido
        )

      # Signal type becomes the action: {"increment", signal.data}
      signal = Signal.new!("increment", %{amount: 5}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # The IncrementAction should have been called
      assert agent.state.domain.counter == 5
      GenServer.stop(pid)
    end

    test("multiple signals processed in sequence", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: ActionBasedAgent,
          id: "multi-signal-test",
          aikido: aikido
        )

      signals = [
        Signal.new!("increment", %{amount: 1}, source: "/test"),
        Signal.new!("increment", %{amount: 2}, source: "/test"),
        Signal.new!("increment", %{amount: 3}, source: "/test")
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
          agent_module: ActionBasedAgent,
          id: "signal-data-test",
          aikido: aikido
        )

      signal = Signal.new!("record", %{message: "hello"}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Fixtures.RecordAction stores the :message value when present
      assert agent.state.domain.messages == ["hello"]
      GenServer.stop(pid)
    end

    test("action can return directives", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: ActionBasedAgent,
          id: "directive-test",
          aikido: aikido
        )

      signal = Signal.new!("emit_test", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Directive was processed (we can't easily verify Emit was executed,
      # but we verified the action ran without error)
      GenServer.stop(pid)
    end

    test("unknown signal type short-circuits with {:error, _} but does not crash", %{
      aikido: aikido
    }) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: ActionBasedAgent,
          id: "unknown-signal-test",
          aikido: aikido
        )

      signal = Signal.new!("unknown_action", %{}, source: "/test")
      # Per ADR 0020, AgentServer.call/4 returns {:error, _} from the chain
      # verbatim — the selector is skipped on the error branch.
      assert {:error, %Aikido.Error.RoutingError{}} =
               Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # The agent should still be functional despite the error
      signal2 = Signal.new!("increment", %{amount: 1}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal2, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end
  end

  describe("direct cmd/2 usage") do
    test "cmd/2 works directly with action module tuples" do
      agent = ActionBasedAgent.new()

      {:ok, updated, _directives} =
        ActionBasedAgent.cmd(agent, {TestActions.IncrementAction, %{amount: 5}})

      assert updated.state.domain.counter == 5
    end
  end
end
