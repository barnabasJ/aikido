defmodule AikidoTest.TelemetryErrorTest do
  use AikidoTest.Case, async: false
  import ExUnit.CaptureLog

  setup do
    previous = Application.fetch_env(:aikido, :telemetry)

    Application.put_env(:aikido, :telemetry,
      log_level: :debug,
      slow_signal_threshold_ms: 60_000,
      interesting_signal_types: []
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aikido, :telemetry, value)
        :error -> Application.delete_env(:aikido, :telemetry)
      end
    end)
  end

  test "fast tagged failures log their bounded reason while fast successes stay quiet" do
    metadata = %{
      agent_id: "error-observation",
      signal_id: "signal-observation",
      signal_type: "ordinary.signal",
      directive_count: 0,
      directive_types: %{}
    }

    log =
      capture_log([level: :debug, metadata: [:signal_id]], fn ->
        Aikido.Telemetry.handle_event(
          [:aikido, :agent_server, :signal, :stop],
          %{duration: 1},
          Map.put(metadata, :error, {:invalid_input, "details"}),
          nil
        )
      end)

    assert log =~ "error={:invalid_input, \"details\"}"
    assert log =~ "signal_id=signal-observation"

    assert "" ==
             capture_log([level: :debug], fn ->
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :signal, :stop],
                 %{duration: 1},
                 metadata,
                 nil
               )
             end)
  end

  test "native reducer failures expose error metadata and correlated logs", context do
    pid = start_server(context, AikidoTest.TestAgents.Counter)
    signal = signal("fail")
    owner = self()
    handler = {__MODULE__, make_ref()}
    event = [:aikido, :agent_server, :signal, :stop]

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _, _, metadata, _ ->
          if metadata.signal_id == signal.id, do: send(owner, {:failed_signal, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      capture_log([level: :debug, metadata: [:signal_id]], fn ->
        assert {:error, _} = Aikido.AgentServer.call(pid, signal, &{:ok, &1.agent.state})
      end)

    assert_receive {:failed_signal, %{error: reason, directive_count: 0}}
    refute is_nil(reason)
    assert log =~ "error="
    assert log =~ "signal_id=#{signal.id}"
    assert Process.alive?(pid)
  end
end
