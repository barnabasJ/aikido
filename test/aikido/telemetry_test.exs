defmodule AikidoTest.TelemetryTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  defp with_telemetry_env(temp_value, fun) when is_function(fun, 0) do
    previous =
      case Application.fetch_env(:aikido, :telemetry) do
        {:ok, value} -> {:ok, value}
        :error -> :error
      end

    try do
      case temp_value do
        :delete -> Application.delete_env(:aikido, :telemetry)
        value -> Application.put_env(:aikido, :telemetry, value)
      end

      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:aikido, :telemetry, value)
        :error -> Application.delete_env(:aikido, :telemetry)
      end
    end
  end

  test "event counters produce a datapoint without a count measurement" do
    counters = Enum.filter(Aikido.Telemetry.metrics(), &match?(%Telemetry.Metrics.Counter{}, &1))
    assert length(counters) == 2

    for metric <- counters do
      assert metric.measurement.(%{duration: 0}) == 1
    end
  end

  describe("setup/0") do
    test "attaches telemetry handlers idempotently" do
      assert :ok = Aikido.Telemetry.setup()
      assert :ok = Aikido.Telemetry.setup()
    end
  end

  describe("handle_event/4") do
    test "handles agent_server signal events" do
      assert :ok =
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :signal, :start],
                 %{system_time: 123},
                 %{agent_id: "test", signal_type: "test.signal"},
                 nil
               )

      assert :ok =
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :signal, :stop],
                 %{duration: 1000},
                 %{agent_id: "test", signal_type: "test.signal", directive_count: 1},
                 nil
               )

      assert :ok =
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :signal, :exception],
                 %{duration: 1000},
                 %{agent_id: "test", signal_type: "test.signal", error: :err},
                 nil
               )
    end

    test "does not emit signal summary logs at the default info level" do
      log =
        with_telemetry_env(:delete, fn ->
          capture_log(fn ->
            assert :ok =
                     Aikido.Telemetry.handle_event(
                       [:aikido, :agent_server, :signal, :stop],
                       %{duration: 1000},
                       %{
                         agent_id: "test",
                         signal_type: "test.signal",
                         directive_count: 2,
                         directive_types: %{"Emit" => 1, "Schedule" => 1}
                       },
                       nil
                     )
          end)
        end)

      assert log == ""
    end

    test "includes directive type summary in signal logs when debug logging is enabled" do
      log =
        with_telemetry_env([log_level: :debug], fn ->
          capture_log(fn ->
            assert :ok =
                     Aikido.Telemetry.handle_event(
                       [:aikido, :agent_server, :signal, :stop],
                       %{duration: 1000},
                       %{
                         agent_id: "test",
                         signal_type: "test.signal",
                         directive_count: 2,
                         directive_types: %{"Emit" => 1, "Schedule" => 1}
                       },
                       nil
                     )
          end)
        end)

      assert log =~ "[signal] type=test.signal directives=2"
      assert log =~ "Emit=1"
      assert log =~ "Schedule=1"
    end

    test "handles agent_server directive events" do
      assert :ok =
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :directive, :start],
                 %{system_time: 123},
                 %{agent_id: "test", directive_type: "Emit"},
                 nil
               )

      assert :ok =
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :directive, :stop],
                 %{duration: 1000},
                 %{agent_id: "test", directive_type: "Emit", result: :ok},
                 nil
               )

      assert :ok =
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :directive, :exception],
                 %{duration: 1000},
                 %{agent_id: "test", directive_type: "Emit", error: :err},
                 nil
               )
    end

    test "handles agent_server cron events" do
      assert :ok =
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :cron, :register],
                 %{},
                 %{agent_id: "test", job_id: :job, cron_expression: "* * * * *"},
                 nil
               )

      assert :ok =
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :cron, :cancel],
                 %{},
                 %{agent_id: "test", job_id: :job},
                 nil
               )

      assert :ok =
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :cron, :restart_scheduled],
                 %{},
                 %{agent_id: "test", job_id: :job, reason: :killed, delay_ms: 500},
                 nil
               )

      assert :ok =
               Aikido.Telemetry.handle_event(
                 [:aikido, :agent_server, :cron, :restart_succeeded],
                 %{},
                 %{agent_id: "test", job_id: :job, cron_expression: "* * * * *"},
                 nil
               )
    end
  end
end
