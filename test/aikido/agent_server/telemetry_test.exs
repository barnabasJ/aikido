defmodule AikidoTest.AgentServer.TelemetryTest do
  use AikidoTest.Case, async: false

  import ExUnit.CaptureLog

  alias Aikido.AgentServer
  alias Aikido.Debug
  alias Aikido.Directives
  alias Jido.Signal
  alias AikidoTest.TestActions

  defmodule EmitDirectiveAction do
    @moduledoc false
    use Aikido.Action

    action do
      name "emit_directive"

      schema do
      end
    end

    def run(_signal, _slice, _opts, _ctx) do
      signal = Signal.new!("test.emitted", %{}, source: "/test")
      {:ok, %{}, [%Directives.Emit{signal: signal}]}
    end
  end

  defmodule ScheduleDirectiveAction do
    @moduledoc false
    use Aikido.Action

    action do
      name "schedule_directive"

      schema do
      end
    end

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, [%Directives.Schedule{delay_ms: 100, message: :tick}]}
    end
  end

  defmodule TelemetryAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name "telemetry_agent"
      path :domain

      schema do
        attribute(:counter, :integer, default: 0)
      end
    end

    signal_routes do
      route "increment", TestActions.IncrementAction
      route "emit_directive", EmitDirectiveAction
      route "schedule_directive", ScheduleDirectiveAction
    end
  end

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

    action_handler_id = "test-action-telemetry-handler-#{:erlang.unique_integer()}"

    :telemetry.attach_many(
      action_handler_id,
      [
        [:aikido, :action, :start],
        [:aikido, :action, :stop]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:action_telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      :telemetry.detach(action_handler_id)
    end)

    {:ok, aikido: context.aikido}
  end

  describe "signal telemetry" do
    test "emits start and stop events for signal processing", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TelemetryAgent,
          id: "telemetry-signal-test",
          aikido: aikido
        )

      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

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

    test "includes directive count in stop event", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TelemetryAgent,
          id: "telemetry-directive-count",
          aikido: aikido
        )

      signal = Signal.new!("emit_directive", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], _, _}

      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], _, metadata}

      assert metadata.directive_count == 1
      assert metadata.directive_types == %{"Emit" => 1}

      GenServer.stop(pid)
    end
  end

  describe "action logging integration" do
    test "suppresses aikido_action start logs when args are not full", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TelemetryAgent,
          id: "telemetry-log-default",
          aikido: aikido
        )

      signal = Signal.new!("increment", %{}, source: "/test")

      log =
        capture_log(fn ->
          assert {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
        end)

      refute log =~ "Executing AikidoTest.TestActions.IncrementAction"
      refute log =~ "with params:"
      refute_receive {:action_telemetry_event, [:aikido, :action, :start], _, _}, 50

      GenServer.stop(pid)
    end

    test "enables verbose aikido_action logs when instance debug is verbose", %{aikido: aikido} do
      Debug.enable(aikido, :verbose)
      on_exit(fn -> Debug.disable(aikido) end)

      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TelemetryAgent,
          id: "telemetry-log-verbose",
          aikido: aikido
        )

      signal = Signal.new!("increment", %{}, source: "/test")

      log =
        capture_log(fn ->
          assert {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)
        end)

      assert log =~ "Executing AikidoTest.TestActions.IncrementAction"
      assert log =~ "with params:"

      assert_receive {:action_telemetry_event, [:aikido, :action, :start], _,
                      %{action: AikidoTest.TestActions.IncrementAction}}

      assert_receive {:action_telemetry_event, [:aikido, :action, :stop], _, _}

      GenServer.stop(pid)
    end
  end

  describe "directive telemetry" do
    test "emits start and stop events for directive execution", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TelemetryAgent,
          id: "telemetry-directive-test",
          aikido: aikido
        )

      # Drain any lifecycle telemetry events emitted during init.
      drain_directive_events()

      signal = Signal.new!("emit_directive", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Signal events
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

    test "reports correct directive type", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TelemetryAgent,
          id: "telemetry-type-test",
          aikido: aikido
        )

      signal = Signal.new!("schedule_directive", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Skip signal events
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], _, _}
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], _, _}

      assert_receive {:telemetry_event, [:aikido, :agent_server, :directive, :start], _,
                      %{directive_type: "Schedule", signal_type: "schedule_directive"} = metadata},
                     500

      assert match?(%Directives.Schedule{}, metadata.directive)

      assert_receive {:telemetry_event, [:aikido, :agent_server, :directive, :stop], _,
                      %{result: :ok, signal_type: "schedule_directive"} = metadata},
                     500

      assert match?(%Directives.Schedule{}, metadata.directive)

      GenServer.stop(pid)
    end
  end

  describe "metadata correctness" do
    test "includes agent_id and agent_module in signal events", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TelemetryAgent,
          id: "telemetry-metadata-test",
          aikido: aikido
        )

      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], _, metadata}

      assert metadata.agent_id == "telemetry-metadata-test"
      assert metadata.agent_module == TelemetryAgent
      assert metadata.signal_type == "increment"

      GenServer.stop(pid)
    end

    test "includes signal_type in directive events", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TelemetryAgent,
          id: "telemetry-signal-type-test",
          aikido: aikido
        )

      signal = Signal.new!("emit_directive", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Skip signal events
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :start], _, _}
      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], _, _}

      assert_receive {:telemetry_event, [:aikido, :agent_server, :directive, :start], _,
                      %{signal_type: "emit_directive", directive_type: "Emit"}},
                     500

      GenServer.stop(pid)
    end
  end

  describe "timing measurements" do
    test "duration is positive for signal processing", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TelemetryAgent,
          id: "telemetry-timing-test",
          aikido: aikido
        )

      signal = Signal.new!("increment", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      assert_receive {:telemetry_event, [:aikido, :agent_server, :signal, :stop], measurements, _}

      assert measurements.duration >= 0

      GenServer.stop(pid)
    end

    test "duration is positive for directive execution", %{aikido: aikido} do
      {:ok, pid} =
        AgentServer.start_link(
          agent_module: TelemetryAgent,
          id: "telemetry-directive-timing",
          aikido: aikido
        )

      signal = Signal.new!("emit_directive", %{}, source: "/test")
      {:ok, _agent} = AgentServer.call(pid, signal, fn s -> {:ok, s.agent} end)

      # Skip signal events
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
