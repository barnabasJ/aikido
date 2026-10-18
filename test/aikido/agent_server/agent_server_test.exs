defmodule AikidoTest.AgentServerTest do
  use AikidoTest.Case, async: true
  @moduletag :capture_log
  alias Aikido.AgentServer
  alias Aikido.Directives
  alias Jido.Signal
  alias AikidoTest.TestActions

  # Test actions with specific directive behavior (not in common_fixtures)
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

  defmodule ScheduleTestAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "schedule_test"}}
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
      scheduled_signal = Signal.new!("scheduled.ping", %{}, source: "/test")
      {:ok, %{}, [%Directives.Schedule{delay_ms: 50, message: scheduled_signal}]}
    end
  end

  defmodule StopTestAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "stop_test"}}
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
      {:ok, %{}, [%Directives.Stop{reason: :normal}]}
    end
  end

  defmodule ErrorTestAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "error_test"}}
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
      error = Aikido.Error.validation_error("Test error", %{field: :test})
      {:ok, %{}, [%Directives.Error{error: error, context: :test}]}
    end
  end

  defmodule TestAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("test_agent")
      path(:domain)

      schema do
        attribute(:counter, :integer, default: 0)
        attribute(:messages, {:array, :term}, default: [])
      end
    end

    alias AikidoTest.TestActions

    signal_routes do
      route("increment", TestActions.IncrementAction)
      route("decrement", TestActions.DecrementAction)
      route("record", TestActions.RecordAction)
      route("emit_test", EmitTestAction)
      route("schedule_test", ScheduleTestAction)
      route("stop_test", StopTestAction)
      route("error_test", ErrorTestAction)
      route("noop", TestActions.NoSchema)
    end
  end

  describe("start_link/1") do
    test("starts with agent module", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test("starts with custom id", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "custom-123", aikido: aikido)

      {:ok, id} = AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert id == "custom-123"
      GenServer.stop(pid)
    end

    test("registers in Registry", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "registry-test", aikido: aikido)

      assert AgentServer.whereis(Aikido.registry_name(aikido), "registry-test") == pid
      GenServer.stop(pid)
    end

    test("starts with initial_state seeded into slice path", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TestAgent,
          id: "prebuilt-456",
          initial_state: %{domain: %{counter: 99}},
          aikido: aikido
        )

      {:ok, %{agent_id: agent_id, counter: counter}} =
        AgentServer.state(pid, fn s ->
          {:ok, %{agent_id: s.agent.id, counter: s.agent.state.domain.counter}}
        end)

      assert agent_id == "prebuilt-456"
      assert counter == 99
      GenServer.stop(pid)
    end

    test("starts with initial_state", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TestAgent,
          initial_state: %{domain: %{counter: 42}},
          aikido: aikido
        )

      {:ok, counter} = AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)
      assert counter == 42
      GenServer.stop(pid)
    end
  end

  describe("start/1") do
    test("starts under DynamicSupervisor", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start(agent_module: TestAgent, id: "dynamic-test", aikido: aikido)
      assert Process.alive?(pid)
      assert AgentServer.whereis(Aikido.registry_name(aikido), "dynamic-test") == pid
      DynamicSupervisor.terminate_child(Aikido.agent_supervisor_name(aikido), pid)
    end

    test("retains permanent restart semantics for directly started agents", %{aikido: aikido}) do
      id = "dynamic-restart-test"
      {:ok, pid} = AgentServer.start(agent_module: TestAgent, id: id, aikido: aikido)
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

      eventually(fn ->
        case AgentServer.whereis(Aikido.registry_name(aikido), id) do
          new_pid when is_pid(new_pid) -> new_pid != pid and Process.alive?(new_pid)
          _ -> false
        end
      end)

      restarted_pid = AgentServer.whereis(Aikido.registry_name(aikido), id)
      assert is_pid(restarted_pid)
      refute restarted_pid == pid
      DynamicSupervisor.terminate_child(Aikido.agent_supervisor_name(aikido), restarted_pid)
    end
  end

  describe("call/3 (sync)") do
    test("processes signal and returns agent", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end

    test("processes multiple signals in sequence", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)

      for _ <- 1..5 do
        signal = Signal.new!("increment", %{}, source: "/test")
        {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      end

      {:ok, counter} = AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)
      assert counter == 5
      GenServer.stop(pid)
    end

    test("records data from signal", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      signal = Signal.new!("record", %{message: "hello"}, source: "/test")
      {:ok, agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.messages == ["hello"]
      GenServer.stop(pid)
    end

    test("works with agent ID string", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "call-id-test", aikido: aikido)

      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end

    test("mailbox-queued messages wait for the in-flight sync call", %{aikido: aikido}) do
      # Under inline signal processing (ADR 0009) the GenServer runs each
      # signal start-to-finish, so messages that arrive during a call wait
      # in the mailbox and land in arrival order afterwards.
      defmodule InlineSlowAction do
        @moduledoc false
        use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
        @persist {:aikido_action_metadata, %{name: "inline_slow"}}
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
          Process.sleep(80)
          {:ok, %{slow_done: true}, []}
        end
      end

      defmodule InlineAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name("inline_agent")
          path(:domain)

          schema do
            attribute(:counter, :integer, default: 0)
            attribute(:slow_done, :boolean, default: false)
          end
        end

        signal_routes do
          route("slow", InlineSlowAction)
          route("increment", TestActions.IncrementAction)
        end
      end

      {:ok, pid} = AgentServer.start_link(agent_module: InlineAgent, aikido: aikido)
      slow_signal = Signal.new!("slow", %{}, source: "/test")

      task =
        Task.async(fn ->
          AgentServer.call(pid, slow_signal, fn s -> {:ok, s.agent} end, timeout: 2000)
        end)

      Process.sleep(15)
      # cast while slow is in-flight — mailbox-queued
      AgentServer.cast(pid, Signal.new!("increment", %{}, source: "/test"))
      assert {:ok, agent} = Task.await(task, 2000)
      assert agent.state.domain.slow_done == true

      await_state_value(pid, fn s ->
        if s.agent.state.domain.counter == 1 do
          true
        end
      end)

      GenServer.stop(pid)
    end

    test("buffers async signals while a sync call is running", %{aikido: aikido}) do
      defmodule BufferedSlowAction do
        @moduledoc false
        use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
        @persist {:aikido_action_metadata, %{name: "buffered_slow"}}
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
          Process.sleep(120)
          {:ok, Map.put(slice, :slow_done, true), []}
        end
      end

      defmodule BufferedIncrementAction do
        @moduledoc false
        use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
        @persist {:aikido_action_metadata, %{name: "buffered_increment"}}
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
          counter = Map.get(slice, :counter, 0)
          {:ok, Map.put(slice, :counter, counter + 1), []}
        end
      end

      defmodule BufferedSignalAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name("buffered_signal_agent")
          path(:domain)

          schema do
            attribute(:counter, :integer, default: 0)
            attribute(:slow_done, :boolean, default: false)
          end
        end

        signal_routes do
          route("slow", BufferedSlowAction)
          route("increment", BufferedIncrementAction)
        end
      end

      {:ok, pid} = AgentServer.start_link(agent_module: BufferedSignalAgent, aikido: aikido)
      slow_signal = Signal.new!("slow", %{}, source: "/test")

      task =
        Task.async(fn ->
          AgentServer.call(pid, slow_signal, fn s -> {:ok, s.agent} end, timeout: 2000)
        end)

      Process.sleep(15)
      increment_signal = Signal.new!("increment", %{}, source: "/test")
      assert :ok = AgentServer.cast(pid, increment_signal)
      assert {:ok, _agent} = Task.await(task, 2000)

      %{counter: counter, slow_done: slow_done} =
        await_state_value(pid, fn s ->
          if s.agent.state.domain.slow_done == true and s.agent.state.domain.counter == 1 do
            %{counter: s.agent.state.domain.counter, slow_done: s.agent.state.domain.slow_done}
          end
        end)

      assert counter == 1
      assert slow_done == true
      GenServer.stop(pid)
    end
  end

  describe("cast/2 (async)") do
    test("processes signal asynchronously", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      signal = Signal.new!("increment", %{}, source: "/test")
      assert :ok = AgentServer.cast(pid, signal)

      await_state_value(pid, fn s ->
        if s.agent.state.domain.counter == 1 do
          true
        end
      end)

      GenServer.stop(pid)
    end

    test("processes multiple signals", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)

      for _ <- 1..5 do
        signal = Signal.new!("increment", %{}, source: "/test")
        AgentServer.cast(pid, signal)
      end

      await_state_value(pid, fn s ->
        if s.agent.state.domain.counter == 5 do
          true
        end
      end)

      GenServer.stop(pid)
    end
  end

  describe("state/3") do
    test("returns projected fields from state via selector", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "state-test", aikido: aikido)

      {:ok, %{id: id, counter: counter, status: status}} =
        AgentServer.state(pid, fn s ->
          {:ok, %{id: s.id, counter: s.agent.state.domain.counter, status: s.status}}
        end)

      assert id == "state-test"
      assert counter == 0
      assert status == :idle
      GenServer.stop(pid)
    end

    test("works with agent ID string", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "state-id-test", aikido: aikido)

      {:ok, id} = AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert id == "state-id-test"
      GenServer.stop(pid)
    end
  end

  describe("whereis/1 and whereis/2") do
    test("whereis/1 returns pid for registered agent using default registry", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "whereis-test-1", aikido: aikido)

      assert AgentServer.whereis(Aikido.registry_name(aikido), "whereis-test-1") == pid
      GenServer.stop(pid)
    end

    test("whereis/1 returns nil for unknown agent", %{aikido: aikido}) do
      assert AgentServer.whereis(Aikido.registry_name(aikido), "nonexistent") == nil
    end

    test("whereis/2 returns pid for registered agent in specific registry", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "whereis-test-2", aikido: aikido)

      assert AgentServer.whereis(Aikido.registry_name(aikido), "whereis-test-2") == pid
      GenServer.stop(pid)
    end

    test("whereis/2 returns nil for unknown agent in specific registry", %{aikido: aikido}) do
      assert AgentServer.whereis(Aikido.registry_name(aikido), "nonexistent-2") == nil
    end

    test("whereis/3 resolves only within the requested partition", %{aikido: aikido}) do
      {:ok, alpha_pid} =
        AgentServer.start_link(
          agent_module: TestAgent,
          id: "whereis-shared",
          aikido: aikido,
          partition: :alpha
        )

      {:ok, beta_pid} =
        AgentServer.start_link(
          agent_module: TestAgent,
          id: "whereis-shared",
          aikido: aikido,
          partition: :beta
        )

      assert AgentServer.whereis(Aikido.registry_name(aikido), "whereis-shared",
               partition: :alpha
             ) == alpha_pid

      assert AgentServer.whereis(Aikido.registry_name(aikido), "whereis-shared", partition: :beta) ==
               beta_pid

      assert AgentServer.whereis(Aikido.registry_name(aikido), "whereis-shared") == nil
      GenServer.stop(alpha_pid)
      GenServer.stop(beta_pid)
    end
  end

  describe("via_tuple/2") do
    test("creates valid via tuple", %{aikido: aikido}) do
      via = AgentServer.via_tuple("via-test", Aikido.registry_name(aikido))
      assert via == {:via, Registry, {Aikido.registry_name(aikido), "via-test"}}
    end

    test("works with custom registry", %{aikido: _aikido}) do
      via = AgentServer.via_tuple("via-test", MyRegistry)
      assert via == {:via, Registry, {MyRegistry, "via-test"}}
    end

    test("via_tuple/3 creates a partitioned registry key", %{aikido: aikido}) do
      via = AgentServer.via_tuple("via-test", Aikido.registry_name(aikido), partition: :alpha)

      assert via ==
               {:via, Registry, {Aikido.registry_name(aikido), {:partition, :alpha, "via-test"}}}
    end
  end

  describe("alive?/1") do
    test("returns true for alive process", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      assert AgentServer.alive?(pid)
      GenServer.stop(pid)
    end

    test("returns false for dead process", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      GenServer.stop(pid)
      refute AgentServer.alive?(pid)
    end

    test("works with agent ID string", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "alive-test", aikido: aikido)

      assert AgentServer.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe("directive execution") do
    @tag :capture_log
    test("Emit directive is processed", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      signal = Signal.new!("emit_test", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Drain loop completes and returns to idle
      await_state_value(pid, fn s ->
        if s.status == :idle do
          true
        end
      end)

      GenServer.stop(pid)
    end

    test("Error directive is processed", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      signal = Signal.new!("error_test", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Drain loop completes and returns to idle
      await_state_value(pid, fn s ->
        if s.status == :idle do
          true
        end
      end)

      GenServer.stop(pid)
    end

    test("Schedule directive schedules a delayed signal", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      signal = Signal.new!("schedule_test", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Wait for scheduled signal to be processed (50ms delay + processing)
      await_state_value(
        pid,
        fn s ->
          if s.status == :idle do
            true
          end
        end,
        timeout: 200
      )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test("Stop directive stops the server", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      ref = Process.monitor(pid)
      signal = Signal.new!("stop_test", %{}, source: "/test")
      AgentServer.cast(pid, signal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end
  end

  describe("unknown signals") do
    test(
      "logs routing error and surfaces {:error, %RoutingError{}} per ADR 0020",
      %{aikido: aikido}
    ) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      signal = Signal.new!("unknown.signal.type", %{}, source: "/test")
      # Per ADR 0020, the chain's error short-circuits the selector and
      # is delivered verbatim to the caller.
      assert {:error, %Aikido.Error.RoutingError{}} =
               AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test("aikido.agent.stop gracefully stops even without explicit routes", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start(agent_module: TestAgent, aikido: aikido)
      ref = Process.monitor(pid)
      signal = Signal.new!("aikido.agent.stop", %{reason: :shutdown}, source: "/test")
      assert :ok = AgentServer.cast(pid, signal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1000
    end
  end

  describe("drain loop") do
    test("processes directives in order", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)

      # Send multiple signals quickly
      for i <- 1..10 do
        signal = Signal.new!("record", %{index: i}, source: "/test")
        AgentServer.cast(pid, signal)
      end

      messages =
        await_state_value(pid, fn s ->
          msgs = s.agent.state.domain.messages

          if length(msgs) == 10 do
            msgs
          end
        end)

      # Verify order is preserved
      indices = Enum.map(messages, & &1.index)
      assert indices == Enum.to_list(1..10)
      GenServer.stop(pid)
    end

    test("status transitions correctly", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)

      # Initially idle
      {:ok, status} = AgentServer.state(pid, fn s -> {:ok, s.status} end)
      assert status == :idle
      GenServer.stop(pid)
    end
  end

  describe("status transitions") do
    test("starts as initializing then transitions to idle", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)

      # After post_init continue, should be idle
      {:ok, status} = AgentServer.state(pid, fn s -> {:ok, s.status} end)
      assert status == :idle
      GenServer.stop(pid)
    end

    test(
      "stays idle across signal handling; never surfaces a :processing state",
      %{aikido: aikido}
    ) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)

      # Under inline signal processing, status stays :idle outside the handler.
      # A synchronous call completes before returning, so external observers
      # always see :idle.
      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      {:ok, status} = AgentServer.state(pid, fn s -> {:ok, s.status} end)
      assert status == :idle
      GenServer.stop(pid)
    end
  end

  describe("scheduled signals") do
    test("scheduled signal is processed after delay", %{aikido: aikido}) do
      defmodule StartScheduleAction do
        @moduledoc false
        use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
        @persist {:aikido_action_metadata, %{name: "start_schedule"}}
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
          scheduled = Signal.new!("scheduled.ping", %{}, source: "/test")
          {:ok, slice, [%Directives.Schedule{delay_ms: 50, message: scheduled}]}
        end
      end

      defmodule ScheduledPingAction do
        @moduledoc false
        use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
        @persist {:aikido_action_metadata, %{name: "scheduled_ping"}}
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
          pings = Map.get(slice, :pings, 0)
          {:ok, %{pings: pings + 1}, []}
        end
      end

      defmodule ScheduleTrackingAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name("schedule_tracking_agent")
          path(:domain)

          schema do
            attribute(:pings, :integer, default: 0)
          end
        end

        signal_routes do
          route("start_schedule", StartScheduleAction)
          route("scheduled.ping", ScheduledPingAction)
        end
      end

      {:ok, pid} = AgentServer.start_link(agent_module: ScheduleTrackingAgent, aikido: aikido)
      signal = Signal.new!("start_schedule", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Before delay
      {:ok, pings_initial} = AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.pings} end)
      assert pings_initial == 0

      # Wait for scheduled signal (50ms delay + processing)
      await_state_value(
        pid,
        fn s ->
          if s.agent.state.domain.pings == 1 do
            true
          end
        end,
        timeout: 200
      )

      GenServer.stop(pid)
    end

    test("multiple scheduled signals are processed", %{aikido: aikido}) do
      defmodule ScheduleManyAction do
        @moduledoc false
        use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
        @persist {:aikido_action_metadata, %{name: "schedule_many"}}
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
          directives =
            for i <- 1..3 do
              sig = Signal.new!("tick", %{n: i}, source: "/test")
              %Directives.Schedule{delay_ms: i * 20, message: sig}
            end

          {:ok, slice, directives}
        end
      end

      defmodule TickAction do
        @moduledoc false
        use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
        @persist {:aikido_action_metadata, %{name: "tick"}}
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

        defp reduce(%Jido.Signal{data: params}, slice, _opts, _ctx) do
          events = Map.get(slice, :events, [])
          {:ok, %{events: events ++ [params.n]}, []}
        end
      end

      defmodule MultiScheduleAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name("multi_schedule_agent")
          path(:domain)

          schema do
            attribute(:events, {:array, :term}, default: [])
          end
        end

        signal_routes do
          route("schedule_many", ScheduleManyAction)
          route("tick", TickAction)
        end
      end

      {:ok, pid} = AgentServer.start_link(agent_module: MultiScheduleAgent, aikido: aikido)
      signal = Signal.new!("schedule_many", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Wait for all 3 scheduled signals (20ms, 40ms, 60ms delays)
      events =
        await_state_value(
          pid,
          fn s ->
            ev = s.agent.state.domain.events

            if ev == [1, 2, 3] do
              ev
            end
          end,
          timeout: 200
        )

      assert events == [1, 2, 3]
      GenServer.stop(pid)
    end

    test("non-signal message is wrapped in signal", %{aikido: aikido}) do
      defmodule ScheduleAtomAction do
        @moduledoc false
        use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
        @persist {:aikido_action_metadata, %{name: "schedule_atom"}}
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
          {:ok, slice, [%Directives.Schedule{delay_ms: 10, message: :timeout}]}
        end
      end

      defmodule AikidoScheduledAction do
        @moduledoc false
        use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
        @persist {:aikido_action_metadata, %{name: "aikido_scheduled"}}
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

        defp reduce(%Jido.Signal{data: params}, _slice, _opts, _ctx) do
          {:ok, %{received: params.message}, []}
        end
      end

      defmodule WrapScheduleAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name("wrap_schedule_agent")
          path(:domain)

          schema do
            attribute(:received, :term, default: nil)
          end
        end

        signal_routes do
          route("schedule_atom", ScheduleAtomAction)
          route("aikido.scheduled", AikidoScheduledAction)
        end
      end

      {:ok, pid} = AgentServer.start_link(agent_module: WrapScheduleAgent, aikido: aikido)
      signal = Signal.new!("schedule_atom", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Wait for scheduled atom message (10ms delay + processing)
      received =
        await_state_value(
          pid,
          fn s ->
            r = s.agent.state.domain.received

            if r == :timeout do
              r
            end
          end,
          timeout: 100
        )

      assert received == :timeout
      GenServer.stop(pid)
    end
  end

  describe("server resolution") do
    test("resolves pid directly", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end

    test("resolves via tuple", %{aikido: aikido}) do
      {:ok, _pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "via-resolve-test", aikido: aikido)

      via = AgentServer.via_tuple("via-resolve-test", Aikido.registry_name(aikido))
      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = AgentServer.call(via, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(AgentServer.whereis(Aikido.registry_name(aikido), "via-resolve-test"))
    end

    test("resolves string id", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "string-resolve-test", aikido: aikido)

      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end

    test("returns error for non-existent server", %{aikido: aikido}) do
      registry = Aikido.registry_name(aikido)

      # Test with string ID that doesn't exist via whereis
      assert AgentServer.whereis(registry, "nonexistent-server") == nil

      # Test that alive? returns false for non-existent string ID lookup
      # (uses whereis internally which returns nil)
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      GenServer.stop(pid)
      refute AgentServer.alive?(pid)
    end

    test("returns error for invalid server reference", %{aikido: _aikido}) do
      signal = Signal.new!("increment", %{}, source: "/test")
      assert {:error, :invalid_server} = AgentServer.call(123, signal, fn s -> {:ok, s.agent} end)

      assert {:error, :invalid_server} =
               AgentServer.call({:invalid}, signal, fn s -> {:ok, s.agent} end)
    end

    test("alive? returns false for non-existent server", %{aikido: aikido}) do
      # Start and stop a server to get a dead pid
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      GenServer.stop(pid)
      refute AgentServer.alive?(pid)
    end
  end

  describe("error handling") do
    test("unknown call returns error", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      result = GenServer.call(pid, :unknown_message)
      assert result == {:error, :unknown_call}
      GenServer.stop(pid)
    end

    test("unknown cast is ignored", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      GenServer.cast(pid, :unknown_message)

      # Verify process is still alive and functional
      eventually(fn -> Process.alive?(pid) end)
      GenServer.stop(pid)
    end

    test("unknown info message is ignored", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      send(pid, :random_message)

      # Verify process is still alive and functional
      eventually(fn -> Process.alive?(pid) end)
      GenServer.stop(pid)
    end
  end

  describe("agent ID handling") do
    test("uses provided ID for the agent", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "struct-id-123", aikido: aikido)

      {:ok, id} = AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert id == "struct-id-123"
      GenServer.stop(pid)
    end

    test("generates ID when not provided", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, aikido: aikido)
      {:ok, id} = AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert is_binary(id)
      assert String.length(id) > 0
      GenServer.stop(pid)
    end

    test("converts atom ID to string", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: TestAgent, id: :atom_id, aikido: aikido)
      {:ok, id} = AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert id == "atom_id"
      GenServer.stop(pid)
    end
  end

  describe("child_spec/1") do
    test("returns valid child spec", %{aikido: _aikido}) do
      spec = AgentServer.child_spec(agent_module: TestAgent, id: "spec-test")
      assert spec.id == "spec-test"

      assert spec.start ==
               {AgentServer, :start_link, [[agent_module: TestAgent, id: "spec-test"]]}

      assert spec.shutdown == 5000
      assert spec.restart == :permanent
      assert spec.type == :worker
    end

    test("uses module as default id", %{aikido: _aikido}) do
      spec = AgentServer.child_spec(agent_module: TestAgent)
      assert spec.id == AgentServer
    end
  end

  describe("termination") do
    test("terminates cleanly with :normal reason", %{aikido: aikido}) do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        AgentServer.start_link(agent_module: TestAgent, id: "terminate-test", aikido: aikido)

      GenServer.stop(pid, :normal)
      assert_receive {:EXIT, ^pid, :normal}, 100
      refute Process.alive?(pid)
    end
  end

  describe("inline signal processing") do
    test("mailbox-serialized processing settles every cast", %{aikido: aikido}) do
      defmodule SlowAction2 do
        @moduledoc false
        use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
        @persist {:aikido_action_metadata, %{name: "slow"}}
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
          Process.sleep(20)
          {:ok, %{processed: true}, []}
        end
      end

      defmodule CounterAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name("counter_agent")
          path(:domain)

          schema do
            attribute(:drain_count, :integer, default: 0)
          end
        end

        signal_routes do
          route("slow", SlowAction2)
        end
      end

      {:ok, pid} = AgentServer.start_link(agent_module: CounterAgent, aikido: aikido)

      signals =
        for _ <- 1..10 do
          Signal.new!("slow", %{}, source: "/test")
        end

      Enum.each(signals, fn sig -> AgentServer.cast(pid, sig) end)

      # Inline processing keeps status at :idle outside the handler; the
      # mailbox drains and a final round-trip confirms everything settled.
      {:ok, _final} =
        AgentServer.call(pid, Signal.new!("slow", %{}, source: "/test"), fn s ->
          {:ok, s.agent}
        end)

      {:ok, status} = AgentServer.state(pid, fn s -> {:ok, s.status} end)
      assert status == :idle
      assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
      GenServer.stop(pid)
    end
  end

  describe("plugin schedules") do
    defmodule ScheduledAction do
      @moduledoc false
      use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
      @persist {:aikido_action_metadata, %{name: "scheduled_action"}}
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
        {:ok, %{scheduled: true}, []}
      end
    end

    defmodule ScheduledSlice do
      @moduledoc false
      use Aikido.Slice

      slice do
        name("scheduled_slice")

        schema do
        end
      end

      schedules do
        schedule("* * * * *", ScheduledAction)
      end
    end

    defmodule AgentWithScheduledSlice do
      @moduledoc false
      use Aikido.Agent

      agent do
        name("agent_with_scheduled_slice")
      end

      slices do
        slice(:scheduled_slice, ScheduledSlice)
      end
    end

    test("registers slice schedules on startup", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: AgentWithScheduledSlice, aikido: aikido)
      {:ok, cron_jobs} = AgentServer.state(pid, fn s -> {:ok, s.cron_jobs} end)
      assert map_size(cron_jobs) == 1
      job_id = {:slice_schedule, :scheduled_slice, ScheduledAction}
      assert Map.has_key?(cron_jobs, job_id)
      cron_pid = Map.get(cron_jobs, job_id)
      assert is_pid(cron_pid)
      assert Process.alive?(cron_pid)
      GenServer.stop(pid)
    end

    test("skips schedules when skip_schedules option is true", %{aikido: aikido}) do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: AgentWithScheduledSlice,
          aikido: aikido,
          skip_schedules: true
        )

      {:ok, cron_jobs} = AgentServer.state(pid, fn s -> {:ok, s.cron_jobs} end)
      assert map_size(cron_jobs) == 0
      GenServer.stop(pid)
    end

    test("cleans up cron jobs on termination", %{aikido: aikido}) do
      {:ok, pid} = AgentServer.start_link(agent_module: AgentWithScheduledSlice, aikido: aikido)
      {:ok, cron_jobs} = AgentServer.state(pid, fn s -> {:ok, s.cron_jobs} end)
      job_id = {:slice_schedule, :scheduled_slice, ScheduledAction}
      cron_pid = Map.get(cron_jobs, job_id)
      assert Process.alive?(cron_pid)
      cron_ref = Process.monitor(cron_pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^cron_ref, :process, ^cron_pid, _reason}, 1000
      refute Process.alive?(cron_pid)
    end

    test "agent exposes schedules/0 accessor" do
      schedules = Aikido.Dsl.Agent.Info.schedules(AgentWithScheduledSlice)
      assert length(schedules) == 1
      [spec] = schedules
      assert spec.cron_expression == "* * * * *"
      assert spec.action == ScheduledAction
      assert spec.job_id == {:slice_schedule, :scheduled_slice, ScheduledAction}
      assert spec.signal_type == "scheduled_slice.__schedule__.scheduled_action"
    end

    test "schedule routes are included in routes/0" do
      routes = Aikido.Dsl.Agent.Info.routes(AgentWithScheduledSlice)

      schedule_route =
        Enum.find(routes, fn {signal_type, _, _} ->
          String.contains?(signal_type, "__schedule__")
        end)

      assert schedule_route != nil
      {signal_type, action, priority} = schedule_route
      assert signal_type == "scheduled_slice.__schedule__.scheduled_action"
      assert action == ScheduledAction
      assert priority < 0
    end
  end
end
