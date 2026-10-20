defmodule AikidoTest.AgentServerTest.StopTestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{},
      directives: [%Aikido.Directives.Stop{reason: :normal}]
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
      attribute :counter, :integer do
        description "Counter used to observe routed state transitions."
        default 0
      end

      attribute :messages, {:array, :term} do
        description "Messages retained by the agent in delivery order."
        default []
      end
    end

    route "increment", {AikidoTest.TestActions, :increment}
    route "decrement", {AikidoTest.TestActions, :decrement}
    route "record", {AikidoTest.TestActions, :record}
    route "stop_test", {AikidoTest.AgentServerTest.TestAgent, :stop_test}
    route "noop", {AikidoTest.TestActions, :optional_input}
  end

  actions do
    action :stop_test, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.AgentServerTest.StopTestAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServerTest.ScheduledAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: %{scheduled: true}, directives: [])
  end
end

defmodule AikidoTest.AgentServerTest.ScheduledSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "scheduled_slice"
  end

  schedules do
    schedule "* * * * *", {AikidoTest.AgentServerTest.ScheduledSlice, :scheduled_action}
  end

  actions do
    action :scheduled_action, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.AgentServerTest.ScheduledAction.Implementation
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

  describe("durable agent activation") do
    test("starts with agent module", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test("starts with custom id", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "custom-123"
        )

      {:ok, id} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert id == "custom-123"
      GenServer.stop(pid)
    end

    test("registers with DurableServer", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "registry-test"
        )

      assert AikidoTest.Case.agent_pid(aikido, "registry-test") == pid
      GenServer.stop(pid)
    end

    test("starts with initial_state seeded into slice path", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "prebuilt-456",
          initial_state: %{domain: %{counter: 99}}
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
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          initial_state: %{domain: %{counter: 42}}
        )

      {:ok, counter} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)

      assert counter == 42
      GenServer.stop(pid)
    end
  end

  describe("durable supervision") do
    test("starts under DurableServer", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "dynamic-test"
        )

      assert Process.alive?(pid)
      assert AikidoTest.Case.agent_pid(aikido, "dynamic-test") == pid
      Aikido.Durable.stop(Aikido.durable_supervisor_name(aikido), pid)
    end

    test("recovers directly started durable agents after a crash", %{aikido: aikido}) do
      id = "dynamic-restart-test"

      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent, id: id)

      restarted_pid = AikidoTest.LifecycleWait.restart(pid)
      assert is_pid(restarted_pid)
      refute restarted_pid == pid
      Aikido.Durable.stop(Aikido.durable_supervisor_name(aikido), restarted_pid)
    end
  end

  describe("call/3 (sync)") do
    test("processes signal and returns agent", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end

    test("processes multiple signals in sequence", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      for _ <- 1..5 do
        signal = Aikido.Signal.new!("increment", %{}, source: "/test")
        {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      end

      {:ok, counter} =
        Aikido.AgentServer.state(pid, fn s -> {:ok, s.agent.state.domain.counter} end)

      assert counter == 5
      GenServer.stop(pid)
    end

    test("records data from signal", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      signal = Aikido.Signal.new!("record", %{message: "hello"}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.messages == ["hello"]
      GenServer.stop(pid)
    end

    test("works with agent ID string", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "call-id-test"
        )

      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
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
          Aikido.Types.ActionResult.new(state: %{slow_done: true}, directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.InlineAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "inline_agent"
          path :domain

          schema do
            attribute :counter, :integer do
              description "Counter used to observe routed state transitions."
              default 0
            end

            attribute :slow_done, :boolean do
              description "Whether the blocked fixture operation has finished."
              default false
            end
          end

          route "slow", {AikidoTest.AgentServerTest.InlineAgent, :inline_slow}
          route "increment", {AikidoTest.TestActions, :increment}
        end

        actions do
          action :inline_slow, Aikido.Types.ActionResult do
            argument :state, :term
            run AikidoTest.AgentServerTest.InlineSlowAction.Implementation
          end
        end
      end

      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.InlineAgent)

      slow_signal = Aikido.Signal.new!("slow", %{}, source: "/test")
      :erlang.trace(pid, true, [:receive])

      task =
        Task.async(fn ->
          Aikido.AgentServer.call(pid, slow_signal, fn s -> {:ok, s.agent} end, timeout: 2000)
        end)

      assert_receive {:trace, ^pid, :receive,
                      {:"$gen_call", _from, {:signal_with_selector, ^slow_signal, _selector}}},
                     1_000

      :erlang.trace(pid, false, [:receive])
      Aikido.AgentServer.cast(pid, Aikido.Signal.new!("increment", %{}, source: "/test"))
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
          Aikido.Types.ActionResult.new(state: Map.put(slice, :slow_done, true), directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.BufferedIncrementAction.Implementation do
        @moduledoc false
        use Ash.Resource.Actions.Implementation
        @impl true
        def run(input, _opts, _context) do
          slice = input.arguments.state
          counter = Map.get(slice, :counter, 0)

          Aikido.Types.ActionResult.new(
            state: Map.put(slice, :counter, counter + 1),
            directives: []
          )
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.BufferedSignalAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "buffered_signal_agent"
          path :domain

          schema do
            attribute :counter, :integer do
              description "Counter used to observe routed state transitions."
              default 0
            end

            attribute :slow_done, :boolean do
              description "Whether the blocked fixture operation has finished."
              default false
            end
          end

          route "slow", {AikidoTest.AgentServerTest.BufferedSignalAgent, :buffered_slow}
          route "increment", {AikidoTest.AgentServerTest.BufferedSignalAgent, :buffered_increment}
        end

        actions do
          action :buffered_slow, Aikido.Types.ActionResult do
            argument :state, :term
            run AikidoTest.AgentServerTest.BufferedSlowAction.Implementation
          end

          action :buffered_increment, Aikido.Types.ActionResult do
            argument :state, :term

            run AikidoTest.AgentServerTest.BufferedIncrementAction.Implementation
          end
        end
      end

      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.BufferedSignalAgent)

      slow_signal = Aikido.Signal.new!("slow", %{}, source: "/test")
      :erlang.trace(pid, true, [:receive])

      task =
        Task.async(fn ->
          Aikido.AgentServer.call(pid, slow_signal, fn s -> {:ok, s.agent} end, timeout: 2000)
        end)

      assert_receive {:trace, ^pid, :receive,
                      {:"$gen_call", _from, {:signal_with_selector, ^slow_signal, _selector}}},
                     1_000

      :erlang.trace(pid, false, [:receive])
      increment_signal = Aikido.Signal.new!("increment", %{}, source: "/test")
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
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
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
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      for _ <- 1..5 do
        signal = Aikido.Signal.new!("increment", %{}, source: "/test")
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
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "state-test"
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
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "state-id-test"
        )

      {:ok, id} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert id == "state-id-test"
      GenServer.stop(pid)
    end
  end

  describe("whereis/1 and lookup") do
    test("whereis/1 returns pid for registered agent using default registry", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "whereis-test-1"
        )

      assert AikidoTest.Case.agent_pid(aikido, "whereis-test-1") == pid
      GenServer.stop(pid)
    end

    test("whereis/1 returns nil for unknown agent", %{aikido: aikido}) do
      assert AikidoTest.Case.agent_pid(aikido, "nonexistent") == nil
    end

    test("lookup returns pid for registered agent in specific registry", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "whereis-test-2"
        )

      assert AikidoTest.Case.agent_pid(aikido, "whereis-test-2") == pid
      GenServer.stop(pid)
    end

    test("lookup returns nil for unknown agent in specific registry", %{aikido: aikido}) do
      assert AikidoTest.Case.agent_pid(aikido, "nonexistent-2") == nil
    end

    test("partitioned lookup resolves only within the requested partition", %{aikido: aikido}) do
      {:ok, alpha_pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "whereis-shared",
          partition: :alpha
        )

      {:ok, beta_pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "whereis-shared",
          partition: :beta
        )

      assert AikidoTest.Case.agent_pid(aikido, "whereis-shared", partition: :alpha) == alpha_pid

      assert AikidoTest.Case.agent_pid(aikido, "whereis-shared", partition: :beta) == beta_pid

      assert AikidoTest.Case.agent_pid(aikido, "whereis-shared") == nil
      GenServer.stop(alpha_pid)
      GenServer.stop(beta_pid)
    end
  end

  describe("alive?/1") do
    test("returns true for alive process", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      assert Aikido.AgentServer.alive?(pid)
      GenServer.stop(pid)
    end

    test("returns false for dead process", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      GenServer.stop(pid)
      refute Aikido.AgentServer.alive?(pid)
    end

    test("works with agent ID string", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "alive-test"
        )

      assert Aikido.AgentServer.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe("directive execution") do
    test("Stop directive stops the server", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      ref = Process.monitor(pid)
      signal = Aikido.Signal.new!("stop_test", %{}, source: "/test")
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
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      signal = Aikido.Signal.new!("unknown.signal.type", %{}, source: "/test")

      assert {:error, %Aikido.Error.RoutingError{}} =
               Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test("aikido.agent.stop gracefully stops even without explicit routes", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      ref = Process.monitor(pid)
      signal = Aikido.Signal.new!("aikido.agent.stop", %{reason: :shutdown}, source: "/test")
      assert :ok = Aikido.AgentServer.cast(pid, signal)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :permanent}}, 1000
    end
  end

  describe("drain loop") do
    test("processes directives in order", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      for i <- 1..10 do
        signal = Aikido.Signal.new!("record", %{index: i}, source: "/test")
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
  end

  describe("status transitions") do
    test("is idle after startup", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      {:ok, status} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.status} end)
      assert status == :idle
      GenServer.stop(pid)
    end

    test(
      "stays idle across signal handling; never surfaces a :processing state",
      %{aikido: aikido}
    ) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
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
            %Aikido.Signal{id: nil, type: "scheduled.ping", data: %{}, source: "/test"}

          Aikido.Types.ActionResult.new(
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
          Aikido.Types.ActionResult.new(state: %{pings: pings + 1}, directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.ScheduleTrackingAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "schedule_tracking_agent"
          path :domain

          schema do
            attribute :pings, :integer do
              description "Number of ping signals handled by the reducer."
              default 0
            end
          end

          route "start_schedule",
                {AikidoTest.AgentServerTest.ScheduleTrackingAgent, :start_schedule}

          route "scheduled.ping",
                {AikidoTest.AgentServerTest.ScheduleTrackingAgent, :scheduled_ping}
        end

        actions do
          action :start_schedule, Aikido.Types.ActionResult do
            argument :state, :term
            run AikidoTest.AgentServerTest.StartScheduleAction.Implementation
          end

          action :scheduled_ping, Aikido.Types.ActionResult do
            argument :state, :term
            run AikidoTest.AgentServerTest.ScheduledPingAction.Implementation
          end
        end
      end

      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.ScheduleTrackingAgent)

      signal = Aikido.Signal.new!("start_schedule", %{}, source: "/test")
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
              sig = %Aikido.Signal{id: nil, type: "tick", data: %{n: i}, source: "/test"}
              %Aikido.Directives.Schedule{delay_ms: i * 20, message: sig}
            end

          Aikido.Types.ActionResult.new(state: slice, directives: directives)
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
          Aikido.Types.ActionResult.new(state: %{events: events ++ [params.n]}, directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.MultiScheduleAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "multi_schedule_agent"
          path :domain

          schema do
            attribute :events, {:array, :term} do
              description "Events recorded in processing order."
              default []
            end
          end

          route "schedule_many", {AikidoTest.AgentServerTest.MultiScheduleAgent, :schedule_many}
          route "tick", {AikidoTest.AgentServerTest.MultiScheduleAgent, :tick}
        end

        actions do
          action :schedule_many, Aikido.Types.ActionResult do
            argument :state, :term
            run AikidoTest.AgentServerTest.ScheduleManyAction.Implementation
          end

          action :tick, Aikido.Types.ActionResult do
            argument :state, :term
            argument :n, :integer, allow_nil?: false
            run AikidoTest.AgentServerTest.TickAction.Implementation
          end
        end
      end

      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.MultiScheduleAgent)

      signal = Aikido.Signal.new!("schedule_many", %{}, source: "/test")
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

          Aikido.Types.ActionResult.new(
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

          Aikido.Types.ActionResult.new(state: %{received: params.message}, directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.WrapScheduleAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "wrap_schedule_agent"
          path :domain

          schema do
            attribute :received, :term do
              description "Payload received by the selected native reducer."
              default nil
            end
          end

          route "schedule_atom", {AikidoTest.AgentServerTest.WrapScheduleAgent, :schedule_atom}

          route "aikido.scheduled",
                {AikidoTest.AgentServerTest.WrapScheduleAgent, :aikido_scheduled}
        end

        actions do
          action :schedule_atom, Aikido.Types.ActionResult do
            argument :state, :term
            run AikidoTest.AgentServerTest.ScheduleAtomAction.Implementation
          end

          action :aikido_scheduled, Aikido.Types.ActionResult do
            argument :state, :term
            argument :message, :term, allow_nil?: false
            run AikidoTest.AgentServerTest.AikidoScheduledAction.Implementation
          end
        end
      end

      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.WrapScheduleAgent)

      signal = Aikido.Signal.new!("schedule_atom", %{}, source: "/test")
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
    test("resolves via tuple", %{aikido: aikido}) do
      {:ok, _pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "via-resolve-test"
        )

      registry = Module.concat(aikido, ExternalRegistry)
      start_supervised!({Registry, keys: :unique, name: registry})
      pid = AikidoTest.Case.agent_pid(aikido, "via-resolve-test")

      {:ok, :registered} =
        Aikido.AgentServer.state(pid, fn _ ->
          Registry.register(registry, "via-resolve-test", nil)
          {:ok, :registered}
        end)

      via = {:via, Registry, {registry, "via-resolve-test"}}
      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(via, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(AikidoTest.Case.agent_pid(aikido, "via-resolve-test"))
    end

    test("resolves string id", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "string-resolve-test"
        )

      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
      {:ok, agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert agent.state.domain.counter == 1
      GenServer.stop(pid)
    end

    test("returns error for non-existent server", %{aikido: aikido}) do
      assert AikidoTest.Case.agent_pid(aikido, "nonexistent-server") == nil

      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      GenServer.stop(pid)
      refute Aikido.AgentServer.alive?(pid)
    end

    test("returns error for invalid server reference", %{aikido: _aikido}) do
      signal = Aikido.Signal.new!("increment", %{}, source: "/test")

      assert {:error, :invalid_server} =
               Aikido.AgentServer.call(123, signal, fn s -> {:ok, s.agent} end)

      assert {:error, :invalid_server} =
               Aikido.AgentServer.call({:invalid}, signal, fn s -> {:ok, s.agent} end)
    end
  end

  describe("error handling") do
    test("unknown call returns error", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      result = GenServer.call(pid, :unknown_message)
      assert result == {:error, :unknown_call}
      GenServer.stop(pid)
    end

    test("unknown cast is ignored", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      GenServer.cast(pid, :unknown_message)
      assert {:ok, :responsive} = Aikido.AgentServer.state(pid, fn _ -> {:ok, :responsive} end)
      GenServer.stop(pid)
    end

    test("unknown info message is ignored", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      send(pid, :random_message)
      assert {:ok, :responsive} = Aikido.AgentServer.state(pid, fn _ -> {:ok, :responsive} end)
      GenServer.stop(pid)
    end
  end

  describe("agent ID handling") do
    test("uses provided ID for the agent", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "struct-id-123"
        )

      {:ok, id} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert id == "struct-id-123"
      GenServer.stop(pid)
    end

    test("generates ID when not provided", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent)

      {:ok, id} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert is_binary(id)
      assert String.length(id) > 0
      GenServer.stop(pid)
    end

    test("accepts opaque durable keys with stable runtime identifiers", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: :atom_id
        )

      {:ok, id} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.id} end)
      assert is_binary(id)

      assert {:error, {:already_started, ^pid}} =
               AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
                 id: :atom_id
               )

      assert {:ok, ^id} = Aikido.AgentServer.state(pid, &{:ok, &1.id})
      GenServer.stop(pid)
    end
  end

  describe("termination") do
    test("terminates cleanly with :normal reason", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.TestAgent,
          id: "terminate-test"
        )

      monitor = Process.monitor(pid)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
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
          Aikido.Types.ActionResult.new(state: %{processed: true}, directives: [])
        end
      end

      defmodule Elixir.AikidoTest.AgentServerTest.CounterAgent do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "counter_agent"
          path :domain

          schema do
            attribute :drain_count, :integer do
              description "Number of queued messages processed during shutdown."
              default 0
            end
          end

          route "slow", {AikidoTest.AgentServerTest.CounterAgent, :slow}
        end

        actions do
          action :slow, Aikido.Types.ActionResult do
            argument :state, :term
            run AikidoTest.AgentServerTest.SlowAction2.Implementation
          end
        end
      end

      {:ok, pid} =
        AikidoTest.Case.start_test_agent(aikido, AikidoTest.AgentServerTest.CounterAgent)

      signals =
        for _ <- 1..10 do
          Aikido.Signal.new!("slow", %{}, source: "/test")
        end

      Enum.each(signals, fn sig -> Aikido.AgentServer.cast(pid, sig) end)

      {:ok, _final} =
        Aikido.AgentServer.call(pid, Aikido.Signal.new!("slow", %{}, source: "/test"), fn s ->
          {:ok, s.agent}
        end)

      {:ok, status} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.status} end)
      assert status == :idle
      assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
      GenServer.stop(pid)
    end
  end

  describe("mounted slice schedules") do
    test("registers slice schedules on startup", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServerTest.AgentWithScheduledSlice
        )

      {:ok, cron_jobs} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.cron_jobs} end)
      assert map_size(cron_jobs) == 1

      [spec] = Aikido.Ash.Agent.Info.schedules(AikidoTest.AgentServerTest.AgentWithScheduledSlice)
      job_id = spec.job_id

      assert Map.has_key?(cron_jobs, job_id)
      cron_pid = Map.get(cron_jobs, job_id)
      assert is_pid(cron_pid)
      assert Process.alive?(cron_pid)
      GenServer.stop(pid)
    end

    test("skips schedules when skip_schedules option is true", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServerTest.AgentWithScheduledSlice,
          skip_schedules: true
        )

      {:ok, cron_jobs} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.cron_jobs} end)
      assert map_size(cron_jobs) == 0
      GenServer.stop(pid)
    end

    test("cleans up cron jobs on termination", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServerTest.AgentWithScheduledSlice
        )

      {:ok, cron_jobs} = Aikido.AgentServer.state(pid, fn s -> {:ok, s.cron_jobs} end)

      [spec] = Aikido.Ash.Agent.Info.schedules(AikidoTest.AgentServerTest.AgentWithScheduledSlice)
      job_id = spec.job_id

      cron_pid = Map.get(cron_jobs, job_id)
      assert Process.alive?(cron_pid)
      cron_ref = Process.monitor(cron_pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^cron_ref, :process, ^cron_pid, _reason}, 1000
      refute Process.alive?(cron_pid)
    end

    test "Info.schedules/1 exposes mounted slice schedules" do
      schedules =
        Aikido.Ash.Agent.Info.schedules(AikidoTest.AgentServerTest.AgentWithScheduledSlice)

      assert length(schedules) == 1
      [spec] = schedules
      assert spec.cron_expression == "* * * * *"
      assert spec.action == {AikidoTest.AgentServerTest.ScheduledSlice, :scheduled_action}

      assert spec.job_id ==
               {:slice_schedule, :scheduled_slice,
                {{AikidoTest.AgentServerTest.ScheduledSlice, :scheduled_action}, "* * * * *",
                 "Etc/UTC", "scheduled_slice.__schedule__.scheduled_action", %{}}}

      assert spec.signal_type == "scheduled_slice.__schedule__.scheduled_action"
    end

    test "schedule routes are included in Info.routes/1" do
      routes = Aikido.Ash.Agent.Info.routes(AikidoTest.AgentServerTest.AgentWithScheduledSlice)

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
