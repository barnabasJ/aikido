defmodule AikidoTest.AgentServerTest.EmitTestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    signal =
      struct!(Jido.Signal, id: nil, type: "test.emitted", data: %{from: "agent"}, source: "/test")

    Aikido.ActionResult.new(state: %{}, directives: [%Aikido.Directives.Emit{signal: signal}])
  end
end

defmodule AikidoTest.AgentServerTest.ScheduleTestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    scheduled_signal =
      struct!(Jido.Signal, id: nil, type: "scheduled.ping", data: %{}, source: "/test")

    Aikido.ActionResult.new(
      state: %{},
      directives: [%Aikido.Directives.Schedule{delay_ms: 50, message: scheduled_signal}]
    )
  end
end

defmodule AikidoTest.AgentServerTest.StopTestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.ActionResult.new(state: %{}, directives: [%Aikido.Directives.Stop{reason: :normal}])
  end
end

defmodule AikidoTest.AgentServerTest.ErrorTestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    error = Aikido.Error.validation_error("Test error", %{field: :test})

    Aikido.ActionResult.new(
      state: %{},
      directives: [%Aikido.Directives.Error{error: error, context: :test}]
    )
  end
end

defmodule AikidoTest.AgentServerTest.TestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "test_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
      attribute :messages, {:array, :term}, default: []
    end

    route "increment", {AikidoTest.TestActions, :increment}
    route "decrement", {AikidoTest.TestActions, :decrement}
    route "record", {AikidoTest.TestActions, :record}
    route "emit_test", {AikidoTest.AgentServerTest.TestAgent, :emit_test}
    route "schedule_test", {AikidoTest.AgentServerTest.TestAgent, :schedule_test}
    route "stop_test", {AikidoTest.AgentServerTest.TestAgent, :stop_test}
    route "error_test", {AikidoTest.AgentServerTest.TestAgent, :error_test}
    route "noop", {AikidoTest.TestActions, :no_schema}
  end

  actions do
    action :emit_test, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServerTest.EmitTestAction.Implementation, action: :run}
    end

    action :schedule_test, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServerTest.ScheduleTestAction.Implementation, action: :run}
    end

    action :stop_test, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServerTest.StopTestAction.Implementation, action: :run}
    end

    action :error_test, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServerTest.ErrorTestAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AgentServerTest.ScheduledAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.ActionResult.new(state: %{scheduled: true}, directives: [])
  end
end

defmodule AikidoTest.AgentServerTest.ScheduledSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "scheduled_slice"

    schema do
    end
  end

  schedules do
    schedule "* * * * *", {AikidoTest.AgentServerTest.ScheduledSlice, :scheduled_action}
  end

  actions do
    action :scheduled_action, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServerTest.ScheduledAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AgentServerTest.AgentWithScheduledSlice do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "agent_with_scheduled_slice"
    slice :scheduled_slice, AikidoTest.AgentServerTest.ScheduledSlice
  end
end

defmodule AikidoTest.AgentServerTest do
  use AikidoTest.Case, async: true
  @moduletag :capture_log

  describe("start_link/1") do
    test("starts with agent module", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test("starts with custom id", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "custom-123",
          aikido: aikido
        )

      {:ok, id} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert id == "custom-123"
      GenServer.stop(pid)
    end

    test("registers in Registry", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "registry-test",
          aikido: aikido
        )

      assert Aikido.whereis(aikido, "registry-test") == pid
      GenServer.stop(pid)
    end

    test("starts with initial_state seeded into slice path", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "prebuilt-456",
          initial_state: %{domain: %{counter: 99}},
          aikido: aikido
        )

      {:ok, %{agent_id: agent_id, counter: counter}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{agent_id: s.agent.id, counter: s.agent.state.domain.counter}}
        end)

      assert agent_id == "prebuilt-456"
      assert counter == 99
      GenServer.stop(pid)
    end

    test("starts with initial_state", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          initial_state: %{domain: %{counter: 42}},
          aikido: aikido
        )

      {:ok, counter} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)

      assert counter == 42
      GenServer.stop(pid)
    end
  end

  describe("start/1") do
    test("starts under DurableServer", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "dynamic-test",
          aikido: aikido
        )

      assert Process.alive?(pid)
      assert Aikido.whereis(aikido, "dynamic-test") == pid
      Aikido.stop_agent(aikido, pid)
    end

    test("recovers directly started durable agents after a crash", %{aikido: aikido}) do
      id = "dynamic-restart-test"

      {:ok, pid} =
        Aikido.AgentServer.start(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: id,
          aikido: aikido
        )

      restarted_pid = AikidoTest.LifecycleWait.restart(pid)
      assert is_pid(restarted_pid)
      refute restarted_pid == pid
      Aikido.stop_agent(aikido, restarted_pid)
    end
  end

  describe("call/3 (sync)") do
    test("processes signal and returns agent", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end

    test("processes multiple signals in sequence", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      for _ <- 1..5 do
        signal = Jido.Signal.new!("increment", %{}, source: "/test")
        {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      end

      {:ok, counter} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)

      assert counter == 5
      GenServer.stop(pid)
    end

    test("records data from signal", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("record", %{message: "hello"}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.messages == ["hello"]
      GenServer.stop(pid)
    end

    test("works with agent ID string", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "call-id-test",
          aikido: aikido
        )

      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end

    test("mailbox-queued messages wait for the in-flight sync call", %{aikido: aikido}) do
      defmodule Elixir.AikidoTest.AgentServerTest.InlineSlowAction.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(_input, _opts, _context) do
          AikidoTest.TestActions.SlowAction.Implementation.work(80)
          Aikido.ActionResult.new(state: %{slow_done: true}, directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.InlineAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "inline_agent"
          path :domain

          schema do
            attribute :counter, :integer, default: 0
            attribute :slow_done, :boolean, default: false
          end

          route "slow", {AikidoTest.AgentServerTest.InlineAgent, :inline_slow}
          route "increment", {AikidoTest.TestActions, :increment}
        end

        actions do
          action :inline_slow, Aikido.ActionResult do
            argument :state, :term
            run {AikidoTest.AgentServerTest.InlineSlowAction.Implementation, action: :run}
          end
        end
      end

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.InlineAgent,
          aikido: aikido
        )

      slow_signal = Jido.Signal.new!("slow", %{}, source: "/test")
      :erlang.trace(pid, true, [:receive])

      task =
        Task.async(fn ->
          Aikido.AgentServer.call(pid, slow_signal, fn s -> {:ok, s.agent} end, timeout: 2000)
        end)

      assert_receive {:trace, ^pid, :receive,
                      {:"$gen_call", _from, {:signal_with_selector, ^slow_signal, _selector}}},
                     1_000

      :erlang.trace(pid, false, [:receive])
      Aikido.AgentServer.cast(pid, Jido.Signal.new!("increment", %{}, source: "/test"))
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
      defmodule Elixir.AikidoTest.AgentServerTest.BufferedSlowAction.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(input, _opts, _context) do
          slice = input.arguments.state
          AikidoTest.TestActions.SlowAction.Implementation.work(120)
          Aikido.ActionResult.new(state: Map.put(slice, :slow_done, true), directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.BufferedIncrementAction.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(input, _opts, _context) do
          slice = input.arguments.state
          counter = Map.get(slice, :counter, 0)
          Aikido.ActionResult.new(state: Map.put(slice, :counter, counter + 1), directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.BufferedSignalAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "buffered_signal_agent"
          path :domain

          schema do
            attribute :counter, :integer, default: 0
            attribute :slow_done, :boolean, default: false
          end

          route "slow", {AikidoTest.AgentServerTest.BufferedSignalAgent, :buffered_slow}
          route "increment", {AikidoTest.AgentServerTest.BufferedSignalAgent, :buffered_increment}
        end

        actions do
          action :buffered_slow, Aikido.ActionResult do
            argument :state, :term
            run {AikidoTest.AgentServerTest.BufferedSlowAction.Implementation, action: :run}
          end

          action :buffered_increment, Aikido.ActionResult do
            argument :state, :term

            run {AikidoTest.AgentServerTest.BufferedIncrementAction.Implementation, action: :run}
          end
        end
      end

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.BufferedSignalAgent,
          aikido: aikido
        )

      slow_signal = Jido.Signal.new!("slow", %{}, source: "/test")
      :erlang.trace(pid, true, [:receive])

      task =
        Task.async(fn ->
          Aikido.AgentServer.call(pid, slow_signal, fn s -> {:ok, s.agent} end, timeout: 2000)
        end)

      assert_receive {:trace, ^pid, :receive,
                      {:"$gen_call", _from, {:signal_with_selector, ^slow_signal, _selector}}},
                     1_000

      :erlang.trace(pid, false, [:receive])
      increment_signal = Jido.Signal.new!("increment", %{}, source: "/test")
      assert :ok = Aikido.AgentServer.cast(pid, increment_signal)
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
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      assert :ok = Aikido.AgentServer.cast(pid, signal)

      await_state_value(pid, fn s ->
        if s.agent.state.domain.counter == 1 do
          true
        end
      end)

      GenServer.stop(pid)
    end

    test("processes multiple signals", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      for _ <- 1..5 do
        signal = Jido.Signal.new!("increment", %{}, source: "/test")
        Aikido.AgentServer.cast(pid, signal)
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
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "state-test",
          aikido: aikido
        )

      {:ok, %{id: id, counter: counter, status: status}} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok, %{id: s.id, counter: s.agent.state.domain.counter, status: s.status}}
        end)

      assert id == "state-test"
      assert counter == 0
      assert status == :idle
      GenServer.stop(pid)
    end

    test("works with agent ID string", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "state-id-test",
          aikido: aikido
        )

      {:ok, id} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert id == "state-id-test"
      GenServer.stop(pid)
    end
  end

  describe("whereis/1 and whereis/2") do
    test("whereis/1 returns pid for registered agent using default registry", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "whereis-test-1",
          aikido: aikido
        )

      assert Aikido.whereis(aikido, "whereis-test-1") == pid
      GenServer.stop(pid)
    end

    test("whereis/1 returns nil for unknown agent", %{aikido: aikido}) do
      assert Aikido.whereis(aikido, "nonexistent") == nil
    end

    test("whereis/2 returns pid for registered agent in specific registry", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "whereis-test-2",
          aikido: aikido
        )

      assert Aikido.whereis(aikido, "whereis-test-2") == pid
      GenServer.stop(pid)
    end

    test("whereis/2 returns nil for unknown agent in specific registry", %{aikido: aikido}) do
      assert Aikido.whereis(aikido, "nonexistent-2") == nil
    end

    test("whereis/3 resolves only within the requested partition", %{aikido: aikido}) do
      {:ok, alpha_pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "whereis-shared",
          aikido: aikido,
          partition: :alpha
        )

      {:ok, beta_pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "whereis-shared",
          aikido: aikido,
          partition: :beta
        )

      assert Aikido.whereis(aikido, "whereis-shared", partition: :alpha) == alpha_pid

      assert Aikido.whereis(aikido, "whereis-shared", partition: :beta) == beta_pid

      assert Aikido.whereis(aikido, "whereis-shared") == nil
      GenServer.stop(alpha_pid)
      GenServer.stop(beta_pid)
    end
  end

  describe("alive?/1") do
    test("returns true for alive process", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      assert Aikido.AgentServer.alive?(pid)
      GenServer.stop(pid)
    end

    test("returns false for dead process", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      GenServer.stop(pid)
      refute Aikido.AgentServer.alive?(pid)
    end

    test("works with agent ID string", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "alive-test",
          aikido: aikido
        )

      assert Aikido.AgentServer.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe("directive execution") do
    @tag :capture_log
    test("Emit directive is processed", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("emit_test", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      await_state_value(pid, fn s ->
        if s.status == :idle do
          true
        end
      end)

      GenServer.stop(pid)
    end

    test("Error directive is processed", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("error_test", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      await_state_value(pid, fn s ->
        if s.status == :idle do
          true
        end
      end)

      GenServer.stop(pid)
    end

    test("Schedule directive schedules a delayed signal", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("schedule_test", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

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
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      ref = Process.monitor(pid)
      signal = Jido.Signal.new!("stop_test", %{}, source: "/test")
      Aikido.AgentServer.cast(pid, signal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end
  end

  describe("unknown signals") do
    test(
      "logs routing error and surfaces {:error, %RoutingError{}}",
      %{aikido: aikido}
    ) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("unknown.signal.type", %{}, source: "/test")

      assert {:error, %Aikido.Error.RoutingError{}} =
               Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test("aikido.agent.stop gracefully stops even without explicit routes", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      ref = Process.monitor(pid)
      signal = Jido.Signal.new!("aikido.agent.stop", %{reason: :shutdown}, source: "/test")
      assert :ok = Aikido.AgentServer.cast(pid, signal)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :permanent}}, 1000
    end
  end

  describe("drain loop") do
    test("processes directives in order", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      for i <- 1..10 do
        signal = Jido.Signal.new!("record", %{index: i}, source: "/test")
        Aikido.AgentServer.cast(pid, signal)
      end

      messages =
        await_state_value(pid, fn s ->
          msgs = s.agent.state.domain.messages

          if length(msgs) == 10 do
            msgs
          end
        end)

      indices = Enum.map(messages, & &1.index)
      assert indices == Enum.to_list(1..10)
      GenServer.stop(pid)
    end

    test("status transitions correctly", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      {:ok, status} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.status} end)
      assert status == :idle
      GenServer.stop(pid)
    end
  end

  describe("status transitions") do
    test("starts as initializing then transitions to idle", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      {:ok, status} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.status} end)
      assert status == :idle
      GenServer.stop(pid)
    end

    test(
      "stays idle across signal handling; never surfaces a :processing state",
      %{aikido: aikido}
    ) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      {:ok, status} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.status} end)
      assert status == :idle
      GenServer.stop(pid)
    end
  end

  describe("scheduled signals") do
    test("scheduled signal is processed after delay", %{aikido: aikido}) do
      defmodule Elixir.AikidoTest.AgentServerTest.StartScheduleAction.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(input, _opts, _context) do
          slice = input.arguments.state

          scheduled =
            struct!(Jido.Signal, id: nil, type: "scheduled.ping", data: %{}, source: "/test")

          Aikido.ActionResult.new(
            state: slice,
            directives: [%Aikido.Directives.Schedule{delay_ms: 50, message: scheduled}]
          )
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.ScheduledPingAction.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(input, _opts, _context) do
          slice = input.arguments.state
          pings = Map.get(slice, :pings, 0)
          Aikido.ActionResult.new(state: %{pings: pings + 1}, directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.ScheduleTrackingAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "schedule_tracking_agent"
          path :domain

          schema do
            attribute :pings, :integer, default: 0
          end

          route "start_schedule",
                {AikidoTest.AgentServerTest.ScheduleTrackingAgent, :start_schedule}

          route "scheduled.ping",
                {AikidoTest.AgentServerTest.ScheduleTrackingAgent, :scheduled_ping}
        end

        actions do
          action :start_schedule, Aikido.ActionResult do
            argument :state, :term
            run {AikidoTest.AgentServerTest.StartScheduleAction.Implementation, action: :run}
          end

          action :scheduled_ping, Aikido.ActionResult do
            argument :state, :term
            run {AikidoTest.AgentServerTest.ScheduledPingAction.Implementation, action: :run}
          end
        end
      end

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.ScheduleTrackingAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("start_schedule", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      {:ok, pings_initial} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.pings} end)

      assert pings_initial == 0

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
      defmodule Elixir.AikidoTest.AgentServerTest.ScheduleManyAction.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(input, _opts, _context) do
          slice = input.arguments.state

          directives =
            for i <- 1..3 do
              sig = struct!(Jido.Signal, id: nil, type: "tick", data: %{n: i}, source: "/test")
              %Aikido.Directives.Schedule{delay_ms: i * 20, message: sig}
            end

          Aikido.ActionResult.new(state: slice, directives: directives)
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.TickAction.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(input, _opts, _context) do
          params = Map.delete(input.arguments, :state)

          slice = input.arguments.state
          events = Map.get(slice, :events, [])
          Aikido.ActionResult.new(state: %{events: events ++ [params.n]}, directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.MultiScheduleAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "multi_schedule_agent"
          path :domain

          schema do
            attribute :events, {:array, :term}, default: []
          end

          route "schedule_many", {AikidoTest.AgentServerTest.MultiScheduleAgent, :schedule_many}
          route "tick", {AikidoTest.AgentServerTest.MultiScheduleAgent, :tick}
        end

        actions do
          action :schedule_many, Aikido.ActionResult do
            argument :state, :term
            run {AikidoTest.AgentServerTest.ScheduleManyAction.Implementation, action: :run}
          end

          action :tick, Aikido.ActionResult do
            argument :state, :term
            argument :n, :integer, allow_nil?: false
            run {AikidoTest.AgentServerTest.TickAction.Implementation, action: :run}
          end
        end
      end

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.MultiScheduleAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("schedule_many", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

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
      defmodule Elixir.AikidoTest.AgentServerTest.ScheduleAtomAction.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(input, _opts, _context) do
          slice = input.arguments.state

          Aikido.ActionResult.new(
            state: slice,
            directives: [%Aikido.Directives.Schedule{delay_ms: 10, message: :timeout}]
          )
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.AikidoScheduledAction.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(input, _opts, _context) do
          params = Map.delete(input.arguments, :state)

          Aikido.ActionResult.new(state: %{received: params.message}, directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.WrapScheduleAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "wrap_schedule_agent"
          path :domain

          schema do
            attribute :received, :term, default: nil
          end

          route "schedule_atom", {AikidoTest.AgentServerTest.WrapScheduleAgent, :schedule_atom}

          route "aikido.scheduled",
                {AikidoTest.AgentServerTest.WrapScheduleAgent, :aikido_scheduled}
        end

        actions do
          action :schedule_atom, Aikido.ActionResult do
            argument :state, :term
            run {AikidoTest.AgentServerTest.ScheduleAtomAction.Implementation, action: :run}
          end

          action :aikido_scheduled, Aikido.ActionResult do
            argument :state, :term
            argument :message, :term, allow_nil?: false
            run {AikidoTest.AgentServerTest.AikidoScheduledAction.Implementation, action: :run}
          end
        end
      end

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.WrapScheduleAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("schedule_atom", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

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
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end

    test("resolves via tuple", %{aikido: aikido}) do
      {:ok, _pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "via-resolve-test",
          aikido: aikido
        )

      registry = Module.concat(aikido, ExternalRegistry)
      start_supervised!({Registry, keys: :unique, name: registry})
      pid = Aikido.whereis(aikido, "via-resolve-test")

      {:ok, :registered} =
        Aikido.AgentServer.state(pid, fn _ ->
          Registry.register(registry, "via-resolve-test", nil)
          {:ok, :registered}
        end)

      via = {:via, Registry, {registry, "via-resolve-test"}}
      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(via, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(Aikido.whereis(aikido, "via-resolve-test"))
    end

    test("resolves string id", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "string-resolve-test",
          aikido: aikido
        )

      signal = Jido.Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end

    test("returns error for non-existent server", %{aikido: aikido}) do
      assert Aikido.whereis(aikido, "nonexistent-server") == nil

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      GenServer.stop(pid)
      refute Aikido.AgentServer.alive?(pid)
    end

    test("returns error for invalid server reference", %{aikido: _aikido}) do
      signal = Jido.Signal.new!("increment", %{}, source: "/test")

      assert {:error, :invalid_server} =
               Aikido.AgentServer.call(123, signal, fn s -> {:ok, s.agent} end)

      assert {:error, :invalid_server} =
               Aikido.AgentServer.call({:invalid}, signal, fn s -> {:ok, s.agent} end)
    end

    test("alive? returns false for non-existent server", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      GenServer.stop(pid)
      refute Aikido.AgentServer.alive?(pid)
    end
  end

  describe("error handling") do
    test("unknown call returns error", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      result = GenServer.call(pid, :unknown_message)
      assert result == {:error, :unknown_call}
      GenServer.stop(pid)
    end

    test("unknown cast is ignored", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      GenServer.cast(pid, :unknown_message)
      assert {:ok, :responsive} = Aikido.AgentServer.state(pid, fn _ -> {:ok, :responsive} end)
      GenServer.stop(pid)
    end

    test("unknown info message is ignored", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      send(pid, :random_message)
      assert {:ok, :responsive} = Aikido.AgentServer.state(pid, fn _ -> {:ok, :responsive} end)
      GenServer.stop(pid)
    end
  end

  describe("agent ID handling") do
    test("uses provided ID for the agent", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "struct-id-123",
          aikido: aikido
        )

      {:ok, id} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert id == "struct-id-123"
      GenServer.stop(pid)
    end

    test("generates ID when not provided", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          aikido: aikido
        )

      {:ok, id} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert is_binary(id)
      assert String.length(id) > 0
      GenServer.stop(pid)
    end

    test("accepts opaque durable keys with stable runtime identifiers", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: :atom_id,
          aikido: aikido
        )

      {:ok, id} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert is_binary(id)

      assert {:error, {:already_started, ^pid}} =
               Aikido.AgentServer.start_link(
                 agent_module: AikidoTest.AgentServerTest.TestAgent,
                 id: :atom_id,
                 aikido: aikido
               )

      assert {:ok, ^id} = Aikido.AgentServer.state(pid, &{:ok, &1.id})
      GenServer.stop(pid)
    end
  end

  describe("termination") do
    test("terminates cleanly with :normal reason", %{aikido: aikido}) do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.TestAgent,
          id: "terminate-test",
          aikido: aikido
        )

      GenServer.stop(pid, :normal)
      assert_receive {:EXIT, ^pid, :normal}, 100
      refute Process.alive?(pid)
    end
  end

  describe("inline signal processing") do
    test("mailbox-serialized processing settles every cast", %{aikido: aikido}) do
      defmodule Elixir.AikidoTest.AgentServerTest.SlowAction2.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(_input, _opts, _context) do
          AikidoTest.TestActions.SlowAction.Implementation.work(20)
          Aikido.ActionResult.new(state: %{processed: true}, directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.CounterAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "counter_agent"
          path :domain

          schema do
            attribute :drain_count, :integer, default: 0
          end

          route "slow", {AikidoTest.AgentServerTest.CounterAgent, :slow}
        end

        actions do
          action :slow, Aikido.ActionResult do
            argument :state, :term
            run {AikidoTest.AgentServerTest.SlowAction2.Implementation, action: :run}
          end
        end
      end

      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.CounterAgent,
          aikido: aikido
        )

      signals =
        for _ <- 1..10 do
          Jido.Signal.new!("slow", %{}, source: "/test")
        end

      Enum.each(signals, fn sig -> Aikido.AgentServer.cast(pid, sig) end)

      {:ok, _final} =
        Aikido.AgentServer.call(pid, Jido.Signal.new!("slow", %{}, source: "/test"), fn s ->
          {:ok, s.agent}
        end)

      {:ok, status} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.status} end)
      assert status == :idle
      assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
      GenServer.stop(pid)
    end
  end

  describe("plugin schedules") do
    (
      nil
      nil
    )

    nil
    nil

    test("registers slice schedules on startup", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.AgentWithScheduledSlice,
          aikido: aikido
        )

      {:ok, cron_jobs} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.cron_jobs} end)
      assert map_size(cron_jobs) == 1

      job_id =
        {:slice_schedule, :scheduled_slice,
         {AikidoTest.AgentServerTest.ScheduledSlice, :scheduled_action}}

      assert Map.has_key?(cron_jobs, job_id)
      cron_pid = Map.get(cron_jobs, job_id)
      assert is_pid(cron_pid)
      assert Process.alive?(cron_pid)
      GenServer.stop(pid)
    end

    test("skips schedules when skip_schedules option is true", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.AgentWithScheduledSlice,
          aikido: aikido,
          skip_schedules: true
        )

      {:ok, cron_jobs} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.cron_jobs} end)
      assert map_size(cron_jobs) == 0
      GenServer.stop(pid)
    end

    test("cleans up cron jobs on termination", %{aikido: aikido}) do
      {:ok, pid} =
        Aikido.AgentServer.start_link(
          agent_module: AikidoTest.AgentServerTest.AgentWithScheduledSlice,
          aikido: aikido
        )

      {:ok, cron_jobs} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.cron_jobs} end)

      job_id =
        {:slice_schedule, :scheduled_slice,
         {AikidoTest.AgentServerTest.ScheduledSlice, :scheduled_action}}

      cron_pid = Map.get(cron_jobs, job_id)
      assert Process.alive?(cron_pid)
      cron_ref = Process.monitor(cron_pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^cron_ref, :process, ^cron_pid, _reason}, 1000
      refute Process.alive?(cron_pid)
    end

    test "agent exposes schedules/0 accessor" do
      schedules =
        Aikido.Dsl.Agent.Info.schedules(AikidoTest.AgentServerTest.AgentWithScheduledSlice)

      assert length(schedules) == 1
      [spec] = schedules
      assert spec.cron_expression == "* * * * *"
      assert spec.action == {AikidoTest.AgentServerTest.ScheduledSlice, :scheduled_action}

      assert spec.job_id ==
               {:slice_schedule, :scheduled_slice,
                {AikidoTest.AgentServerTest.ScheduledSlice, :scheduled_action}}

      assert spec.signal_type == "scheduled_slice.__schedule__.scheduled_action"
    end

    test "schedule routes are included in routes/0" do
      routes = Aikido.Dsl.Agent.Info.routes(AikidoTest.AgentServerTest.AgentWithScheduledSlice)

      schedule_route =
        Enum.find(routes, fn {signal_type, _, _} ->
          String.contains?(signal_type, "__schedule__")
        end)

      assert schedule_route != nil
      {signal_type, action, priority} = schedule_route
      assert signal_type == "scheduled_slice.__schedule__.scheduled_action"
      assert action == {AikidoTest.AgentServerTest.ScheduledSlice, :scheduled_action}
      assert priority < 0
    end
  end
end
