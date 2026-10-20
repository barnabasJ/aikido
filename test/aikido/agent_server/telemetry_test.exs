defmodule AikidoTest.AgentServer.TelemetryTest.EmitDirectiveAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    signal = %Aikido.Signal{id: nil, type: "test.emitted", data: %{}, source: "/test"}

    Aikido.Types.ActionResult.new(
      state: %{},
      directives: [%Aikido.Directives.Emit{signal: signal}]
    )
  end
end

defmodule AikidoTest.AgentServer.TelemetryTest.ScheduleDirectiveAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{},
      directives: [%Aikido.Directives.Schedule{delay_ms: 100, message: :tick}]
    )
  end
end

defmodule AikidoTest.AgentServer.TelemetryTest.TelemetryAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "telemetry_agent"
    path :domain

    schema do
      attribute :counter, :integer, default: 0
    end

    route "increment", {AikidoTest.TestActions, :increment}
    route "emit_directive", {AikidoTest.AgentServer.TelemetryTest.TelemetryAgent, :emit_directive}

    route "schedule_directive",
          {AikidoTest.AgentServer.TelemetryTest.TelemetryAgent, :schedule_directive}
  end

  actions do
    action :emit_directive, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.AgentServer.TelemetryTest.EmitDirectiveAction.Implementation
    end

    action :schedule_directive, Aikido.Types.ActionResult do
      argument :state, :term

      run AikidoTest.AgentServer.TelemetryTest.ScheduleDirectiveAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServer.TelemetryTest do
  use AikidoTest.Case, async: false

  setup context do
    test_pid = self()
    handler_id = "test-telemetry-handler-#{:erlang.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      [
        [:aikido, :agent_server, :signal, :start],
        [:aikido, :agent_server, :signal, :stop],
        [:aikido, :agent_server, :signal, :exception],
        [:aikido, :agent_server, :directive, :start],
        [:aikido, :agent_server, :directive, :stop],
        [:aikido, :agent_server, :directive, :exception],
        [:aikido, :agent_server, :queue, :overflow]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    {:ok, aikido: context.aikido}
  end

  describe("signal telemetry") do
    test("emits start and stop events for signal processing", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.TelemetryTest.TelemetryAgent,
          id: "telemetry-signal-test"
        )

      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], measurements,
                      metadata}

      assert is_integer(measurements.system_time)
      assert metadata.agent_id == "telemetry-signal-test"
      assert metadata.signal_type == "increment"

      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], measurements,
                      metadata}

      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert metadata.directive_count == 0
      GenServer.stop(pid)
    end

    test("includes directive count in stop event", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.TelemetryTest.TelemetryAgent,
          id: "telemetry-directive-count"
        )

      signal = Aikido.Signal.new!("emit_directive", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], _, _}
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], _, metadata}
      assert metadata.directive_count == 1
      assert metadata.directive_types == %{"Emit" => 1}
      GenServer.stop(pid)
    end
  end

  describe("directive telemetry") do
    test("emits start and stop events for directive execution", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.TelemetryTest.TelemetryAgent,
          id: "telemetry-directive-test"
        )

      drain_directive_events()
      signal = Aikido.Signal.new!("emit_directive", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], _, _}
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], _, _}
      measurements = wait_for_directive_event(:start, "emit_directive")
      assert is_integer(measurements.system_time)
      measurements = wait_for_directive_event(:stop, "emit_directive")
      assert is_integer(measurements.duration)
      GenServer.stop(pid)
    end

    defp drain_directive_events do
      receive do
        {:telemetry_event, [:aikido, :agent_server, :directive, _], _, _} ->
          drain_directive_events()
      after
        20 -> :ok
      end
    end

    defp wait_for_directive_event(phase, signal_type) do
      receive do
        {:telemetry_event, [:aikido, :agent_server, :directive, ^phase], measurements,
         %{signal_type: ^signal_type}} ->
          measurements

        {:telemetry_event, [:aikido, :agent_server, :directive, _], _, _} ->
          wait_for_directive_event(phase, signal_type)
      after
        500 -> flunk("did not receive directive #{phase} event for signal_type=#{signal_type}")
      end
    end

    test("reports correct directive type", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.TelemetryTest.TelemetryAgent,
          id: "telemetry-type-test"
        )

      signal = Aikido.Signal.new!("schedule_directive", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], _, _}
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], _, _}

      assert_receive {:telemetry_event, [:aikido, :agent_server, :directive, :start], _,
                      %{directive_type: "Schedule", signal_type: "schedule_directive"} = metadata},
                     500

      assert metadata.signal_id == signal.id
      assert match?(%Aikido.Directives.Schedule{}, metadata.directive)

      assert_receive {:telemetry_event, [:aikido, :agent_server, :directive, :stop], _,
                      %{result: :ok, signal_type: "schedule_directive"} = metadata},
                     500

      assert metadata.signal_id == signal.id
      assert match?(%Aikido.Directives.Schedule{}, metadata.directive)
      GenServer.stop(pid)
    end
  end

  describe("metadata correctness") do
    test("includes agent_id and agent_module in signal events", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.TelemetryTest.TelemetryAgent,
          id: "telemetry-metadata-test"
        )

      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], _, metadata}
      assert metadata.agent_id == "telemetry-metadata-test"
      assert metadata.agent_module == AikidoTest.AgentServer.TelemetryTest.TelemetryAgent
      assert metadata.signal_type == "increment"
      GenServer.stop(pid)
    end

    test("includes signal_type in directive events", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.TelemetryTest.TelemetryAgent,
          id: "telemetry-signal-type-test"
        )

      signal = Aikido.Signal.new!("emit_directive", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], _, _}
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], _, _}

      assert_receive {:telemetry_event, [:aikido, :agent_server, :directive, :start], _,
                      %{signal_type: "emit_directive", directive_type: "Emit"}},
                     500

      GenServer.stop(pid)
    end
  end

  describe("timing measurements") do
    test("duration is positive for signal processing", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.TelemetryTest.TelemetryAgent,
          id: "telemetry-timing-test"
        )

      signal = Aikido.Signal.new!("increment", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], measurements, _}
      assert measurements.duration >= 0
      GenServer.stop(pid)
    end

    test("duration is positive for directive execution", %{aikido: aikido}) do
      {:ok, pid} =
        AikidoTest.Case.start_test_agent(
          aikido,
          AikidoTest.AgentServer.TelemetryTest.TelemetryAgent,
          id: "telemetry-directive-timing"
        )

      signal = Aikido.Signal.new!("emit_directive", %{}, source: "/test")
      {:ok, _agent} = Aikido.AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], _, _}
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], _, _}

      assert_receive {:telemetry_event, [:aikido, :agent_server, :directive, :stop], measurements,
                      %{signal_type: "emit_directive", result: :ok}},
                     500

      assert measurements.duration >= 0
      GenServer.stop(pid)
    end
  end
end
