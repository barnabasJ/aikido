defmodule AikidoTest.Telemetry.ConfigTest do
  use ExUnit.Case, async: false
  @test_instance :"aikido_observe_config_#{System.unique_integer([:positive])}"

  setup do
    Aikido.Debug.disable(@test_instance)

    on_exit(fn ->
      Application.delete_env(:aikido, :telemetry)
      Application.delete_env(:aikido, :observability)
      Aikido.Debug.disable(@test_instance)
    end)

    :ok
  end

  describe("telemetry_log_level/1") do
    test "returns default when no config set" do
      assert Aikido.Telemetry.Config.telemetry_log_level(nil) ==
               Aikido.Config.Defaults.telemetry_log_level()
    end

    test "reads from global config" do
      Application.put_env(:aikido, :telemetry, log_level: :info)
      assert Aikido.Telemetry.Config.telemetry_log_level(nil) == :info
    end

    test "falls back to default when global value is invalid" do
      Application.put_env(:aikido, :telemetry, log_level: :invalid)

      assert Aikido.Telemetry.Config.telemetry_log_level(nil) ==
               Aikido.Config.Defaults.telemetry_log_level()
    end

    test "nil instance skips debug override" do
      assert Aikido.Telemetry.Config.telemetry_log_level(nil) ==
               Aikido.Config.Defaults.telemetry_log_level()
    end
  end

  describe("slow_signal_threshold_ms/1") do
    test "returns default" do
      assert Aikido.Telemetry.Config.slow_signal_threshold_ms(nil) ==
               Aikido.Config.Defaults.slow_signal_threshold_ms()
    end

    test "reads from global config" do
      Application.put_env(:aikido, :telemetry, slow_signal_threshold_ms: 50)
      assert Aikido.Telemetry.Config.slow_signal_threshold_ms(nil) == 50
    end

    test "falls back to default when value is invalid" do
      Application.put_env(:aikido, :telemetry, slow_signal_threshold_ms: -5)

      assert Aikido.Telemetry.Config.slow_signal_threshold_ms(nil) ==
               Aikido.Config.Defaults.slow_signal_threshold_ms()
    end
  end

  describe("slow_directive_threshold_ms/1") do
    test "returns default" do
      assert Aikido.Telemetry.Config.slow_directive_threshold_ms(nil) ==
               Aikido.Config.Defaults.slow_directive_threshold_ms()
    end

    test "falls back to default when value is invalid" do
      Application.put_env(:aikido, :telemetry, slow_directive_threshold_ms: "slow")

      assert Aikido.Telemetry.Config.slow_directive_threshold_ms(nil) ==
               Aikido.Config.Defaults.slow_directive_threshold_ms()
    end
  end

  describe("interesting_signal_types/1") do
    test "returns default list" do
      types = Aikido.Telemetry.Config.interesting_signal_types(nil)
      assert is_list(types)
    end

    test "falls back to defaults when list contains non-strings" do
      Application.put_env(:aikido, :telemetry, interesting_signal_types: ["ok", 123])

      assert Aikido.Telemetry.Config.interesting_signal_types(nil) ==
               Aikido.Config.Defaults.interesting_signal_types()
    end
  end

  describe("trace_enabled?/1") do
    test "false by default" do
      refute Aikido.Telemetry.Config.trace_enabled?(nil)
    end

    test "true when log level is trace" do
      Application.put_env(:aikido, :telemetry, log_level: :trace)
      assert Aikido.Telemetry.Config.trace_enabled?(nil)
    end
  end

  describe("debug_enabled?/1") do
    test "false by default (default log level is :info)" do
      refute Aikido.Telemetry.Config.debug_enabled?(nil)
    end

    test "false when log level is info" do
      Application.put_env(:aikido, :telemetry, log_level: :info)
      refute Aikido.Telemetry.Config.debug_enabled?(nil)
    end
  end

  describe("tracer/1") do
    test "has no tracer by default" do
      assert Aikido.Telemetry.Config.tracer(nil) == nil
    end

    test "returns configured tracer when it implements the contract" do
      Application.put_env(:aikido, :observability, tracer: AikidoTest.Support.TestTracer)

      assert Aikido.Telemetry.Config.tracer(nil) == AikidoTest.Support.TestTracer
    end

    test "falls back to default tracer when configured module is invalid" do
      Application.put_env(:aikido, :observability, tracer: Date)
      assert Aikido.Telemetry.Config.tracer(nil) == Aikido.Config.Defaults.tracer()
    end
  end

  describe("debug_max_events/1") do
    test "returns default by default" do
      assert Aikido.Telemetry.Config.debug_max_events(nil) ==
               Aikido.Config.Defaults.debug_max_events()
    end

    test "reads from global telemetry config" do
      Application.put_env(:aikido, :telemetry, debug_max_events: 1000)
      assert Aikido.Telemetry.Config.debug_max_events(nil) == 1000
    end

    test "falls back to default when value is invalid" do
      Application.put_env(:aikido, :telemetry, debug_max_events: -1)

      assert Aikido.Telemetry.Config.debug_max_events(nil) ==
               Aikido.Config.Defaults.debug_max_events()
    end
  end

  describe("interesting_signal_type?/2") do
    test "returns true for types listed in interesting_signal_types config" do
      Application.put_env(:aikido, :telemetry, interesting_signal_types: ["my.app.event"])
      on_exit(fn -> Application.delete_env(:aikido, :telemetry) end)
      assert Aikido.Telemetry.Config.interesting_signal_type?(nil, "my.app.event")
    end

    test "returns false for unknown types" do
      refute Aikido.Telemetry.Config.interesting_signal_type?(nil, "some.random.signal")
    end
  end
end
