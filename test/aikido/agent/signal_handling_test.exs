defmodule AikidoTest.Agent.SignalHandlingTest.Signals.EmitTest do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "emit_test"

    schema do
      attribute :recipient, :term do
        description "Process that receives the signal emitted by the command."
        allow_nil? false
      end
    end
  end
end

defmodule AikidoTest.Agent.SignalHandlingTest.Actions.EmitTestSignal do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    signal =
      %Aikido.Signal{id: nil, type: "test.emitted", data: %{from: "agent"}, source: "/test"}

    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [%Aikido.Directives.Emit{signal: signal, target: input.arguments.recipient}]
    )
  end
end

defmodule AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "action_based_agent"
    path :domain

    schema do
      attribute :counter, :integer do
        description "Counter used to observe routed state transitions."
        default 0
      end

      attribute :messages, {:array, :term} do
        description "Messages retained by the agent in delivery order."
        default []
      end
    end

    route AikidoTest.TestSignals.Increment, AikidoTest.TestActions.Actions.IncrementCounter
    route AikidoTest.TestSignals.Decrement, AikidoTest.TestActions.Actions.DecrementCounter
    route AikidoTest.TestSignals.Record, AikidoTest.TestActions.Actions.RecordMessage

    route AikidoTest.Agent.SignalHandlingTest.Signals.EmitTest,
          AikidoTest.Agent.SignalHandlingTest.Actions.EmitTestSignal
  end
end

defmodule AikidoTest.Agent.SignalHandlingTest do
  @moduledoc """
  Tests signal routing through AgentServer.

  Signal handling architecture:
  1. Signals arrive at AgentServer
  2. AgentServer routes signals to native Ash actions
  3. Ash validates and executes the actions
  4. AgentServer accepts the returned state and executes its directives
  """
  use AikidoTest.Case, async: true

  describe("signal routing via AgentServer") do
    test("signals are routed to actions by type", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
          id: "signal-route-test"
        )

      signal = Aikido.Signal.new!("increment", %{amount: 5}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 5
      GenServer.stop(pid)
    end

    test("multiple signals processed in sequence", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
          id: "multi-signal-test"
        )

      signals = [
        Aikido.Signal.new!("increment", %{amount: 1}, source: "/test"),
        Aikido.Signal.new!("increment", %{amount: 2}, source: "/test"),
        Aikido.Signal.new!("increment", %{amount: 3}, source: "/test")
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
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
          id: "signal-data-test"
        )

      signal = Aikido.Signal.new!("record", %{data: %{message: "hello"}}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.messages == ["hello"]
      GenServer.stop(pid)
    end

    test("action can return directives", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
          id: "directive-test",
          initial_state: %{counter: 7}
        )

      signal = Aikido.Signal.new!("emit_test", %{recipient: self()}, source: "/test")
      assert {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 7
      assert_receive {:signal, %Aikido.Signal{type: "test.emitted", data: %{from: "agent"}}}
      GenServer.stop(pid)
    end

    test("unknown signal type short-circuits with {:error, _} but does not crash", %{
      aikido: aikido
    }) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
          id: "unknown-signal-test"
        )

      signal = Aikido.Signal.new!("unknown_action", %{}, source: "/test")

      assert {:error, %Aikido.Error.RoutingError{}} =
               Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      signal2 = Aikido.Signal.new!("increment", %{amount: 1}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal2, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end
  end

  describe("native action state application") do
    test "native action references update state" do
      agent = AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent.initialize!()

      {:ok, %{agent: updated}, _directives} =
        Aikido.AgentServer.apply_actions(
          %Aikido.Signal{id: nil, type: "test.action", data: %{}, source: "/test"},
          Map.merge(
            Aikido.Signal.ctx(%Aikido.Signal{
              id: nil,
              type: "test.action",
              data: %{},
              source: "/test"
            }),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Agent.SignalHandlingTest.ActionBasedAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{AikidoTest.TestAgents.Counter, :increment}, %{amount: 5}}]
        )

      assert updated.state.domain.counter == 5
    end
  end
end
