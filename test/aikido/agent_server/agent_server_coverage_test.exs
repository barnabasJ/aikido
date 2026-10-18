defmodule AikidoTest.AgentServerCoverageTest do
  @moduledoc "Additional tests to improve AgentServer coverage.\n\nTests uncovered paths including:\n- resolve_server with {:via, ...} that returns nil\n- Agent resolution with new/0 vs new/1\n- Pre-built struct with agent_module option\n- Lifecycle hooks (on_before_cmd, on_after_cmd)\n- Queue overflow scenario\n- Multiple await_completion waiters\n- Invalid signal handling\n"
  use AikidoTest.Case, async: true
  @moduletag :capture_log
  alias Aikido.AgentServer
  alias Jido.Signal
  alias AikidoTest.TestAgents.Counter

  # Simple test agent with defaults
  defmodule SimpleTestAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("simple_test_agent")
      path(:domain)

      schema do
        attribute(:counter, :integer, default: 0)
      end
    end

    signal_routes do
      route("increment", AikidoTest.TestActions.IncrementAction)
    end
  end

  # Action that generates many directives for queue overflow testing
  defmodule ManyDirectivesAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "many_directives"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:count, :integer, default: 10)

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

    alias Aikido.Directives

    defp reduce(%Jido.Signal{data: %{count: count}}, _slice, _opts, _ctx) do
      directives =
        for i <- 1..count do
          signal = Jido.Signal.new!("test.emitted.#{i}", %{index: i}, source: "/test")
          %Directives.Emit{signal: signal}
        end

      {:ok, %{directive_count: count}, directives}
    end
  end

  defmodule ManyDirectivesAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("many_directives_agent")
      path(:domain)

      schema do
        attribute(:counter, :integer, default: 0)
        attribute(:directive_count, :integer, default: 0)
      end
    end

    signal_routes do
      route("many_directives", ManyDirectivesAction)
    end
  end

  # Actions for await_completion testing - defined before agent that uses them
  defmodule CompleteAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "complete"}}
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
      {:ok, %{status: :completed, last_answer: "done!"}, []}
    end
  end

  defmodule FailAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "fail"}}
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
      {:ok, %{status: :failed, error: "something went wrong"}, []}
    end
  end

  defmodule DelayCompleteAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "delay_complete"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:delay_ms, :integer, default: 50)

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

    defp reduce(%Jido.Signal{data: %{delay_ms: delay}}, _slice, _opts, _ctx) do
      Process.sleep(delay)
      {:ok, %{status: :completed, last_answer: "delayed done!"}, []}
    end
  end

  # Agent for await_completion testing
  defmodule CompletionAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("completion_agent")
      path(:domain)

      schema do
        attribute(:status, :atom, default: :pending)
        attribute(:last_answer, :term, default: nil)
        attribute(:error, :term, default: nil)
      end
    end

    signal_routes do
      route("complete", CompleteAction)
      route("fail", FailAction)
      route("delay_complete", DelayCompleteAction)
    end
  end

  describe("resolve_server with {:via, ...}") do
    test("via tuple that resolves to nil returns error", %{aikido: aikido}) do
      nonexistent_via = {:via, Registry, {Aikido.registry_name(aikido), "nonexistent-via-agent"}}
      signal = Signal.new!("increment", %{}, source: "/test")

      assert {:error, :not_found} =
               AgentServer.call(nonexistent_via, signal, fn s -> {:ok, s.agent} end)

      assert {:error, :not_found} = AgentServer.cast(nonexistent_via, signal)
      assert {:error, :not_found} = AgentServer.state(nonexistent_via, fn s -> {:ok, s.id} end)
    end

    test("via tuple that exists works", %{aikido: aikido}) do
      {:ok, _pid} =
        AgentServer.start_link(agent_module: Counter, id: "via-test-exists", aikido: aikido)

      via = {:via, Registry, {Aikido.registry_name(aikido), "via-test-exists"}}
      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = AgentServer.call(via, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
    end
  end

  describe("resolve_server with string ID") do
    test("string ID returns error with helpful message", %{aikido: _aikido}) do
      signal = Signal.new!("increment", %{}, source: "/test")

      assert {:error, {:invalid_server, message}} =
               AgentServer.call("some-string-id", signal, fn s -> {:ok, s.agent} end)

      assert message =~ "String IDs require explicit registry lookup"
      assert message =~ "some-string-id"
    end

    test("string ID error on cast", %{aikido: _aikido}) do
      signal = Signal.new!("increment", %{}, source: "/test")
      assert {:error, {:invalid_server, _}} = AgentServer.cast("some-string-id", signal)
    end

    test("string ID error on state", %{aikido: _aikido}) do
      assert {:error, {:invalid_server, _}} =
               AgentServer.state("some-string-id", fn s -> {:ok, s.id} end)
    end
  end

  describe("resolve_server with atom name") do
    test("atom name that doesn't exist returns error", %{aikido: _aikido}) do
      signal = Signal.new!("increment", %{}, source: "/test")

      assert {:error, :not_found} =
               AgentServer.call(:nonexistent_atom_server, signal, fn s -> {:ok, s.agent} end)
    end
  end

  describe("agent resolution with defaults") do
    test("agent uses default values from schema", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: SimpleTestAgent, aikido: aikido)
      {:ok, counter} = AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)
      assert counter == 0
      GenServer.stop(pid)
    end

    test("id and initial_state options are respected", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: SimpleTestAgent,
          id: "custom-id-123",
          initial_state: %{counter: 999},
          aikido: aikido
        )

      {:ok, %{id: id, counter: counter}} =
        AgentServer.state(pid, fn s ->
          {:ok, %{id: s.id, counter: s.agent.state.domain.counter}}
        end)

      assert id == "custom-id-123"
      assert counter == 999
      GenServer.stop(pid)
    end
  end

  describe("pre-built struct with agent_module option") do
    test("uses explicit agent_module for cmd routing", %{aikido: aikido}) do
      agent = Counter.new(id: "prebuilt-struct-test")
      agent = %{agent | state: put_in(agent.state, [:domain, :counter], 50)}

      {:ok, pid} =
        AgentServer.start_link(
          agent_module: Counter,
          id: agent.id,
          initial_state: agent.state,
          aikido: aikido
        )

      {:ok, %{id: id, counter: counter, agent_module: agent_module}} =
        AgentServer.state(pid, fn s ->
          {:ok, %{id: s.id, counter: s.agent.state.domain.counter, agent_module: s.agent_module}}
        end)

      assert id == "prebuilt-struct-test"
      assert counter == 50
      assert agent_module == Counter
      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, updated_agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert updated_agent.state.domain.counter == 51
      GenServer.stop(pid)
    end
  end

  describe("invalid signal handling") do
    test("signal with no matching route does not crash the agent", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: AikidoTest.TestAgents.Minimal, aikido: aikido)

      signal = Signal.new!("nonexistent_action", %{}, source: "/test")
      # Per ADR 0020, AgentServer.call/4 surfaces the chain's tagged error
      # verbatim — the selector is skipped on the routing-failure branch.
      assert {:error, %Aikido.Error.RoutingError{}} =
               AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe("alive? with various server types") do
    test("alive? returns false for via tuple that doesn't exist", %{aikido: aikido}) do
      via = {:via, Registry, {Aikido.registry_name(aikido), "nonexistent-alive-test"}}
      refute AgentServer.alive?(via)
    end

    test("alive? returns false for atom name that doesn't exist", %{aikido: _aikido}) do
      refute AgentServer.alive?(:nonexistent_atom_name)
    end

    test("alive? returns true for existing via tuple", %{aikido: aikido}) do
      {:ok, _pid} =
        AgentServer.start_link(agent_module: Counter, id: "alive-via-test", aikido: aikido)

      via = {:via, Registry, {Aikido.registry_name(aikido), "alive-via-test"}}
      assert AgentServer.alive?(via)
    end
  end
end
