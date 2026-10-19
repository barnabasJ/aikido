defmodule AikidoTest.Observe.ConfigTest.ValidTracer do
  @moduledoc false
  @behaviour Aikido.Observe.Tracer
  @impl true
  def span_start(_event_prefix, _metadata) do
    :ok
  end

  @impl true
  def span_stop(_ctx, _measurements) do
    :ok
  end

  @impl true
  def span_exception(_ctx, _kind, _reason, _stacktrace) do
    :ok
  end
end

defmodule AikidoTest.Observe.ConfigTest do
  use ExUnit.Case, async: false
  @test_instance :"aikido_observe_config_#{System.unique_integer([:positive])}"

  setup do
    Aikido.Debug.reset(@test_instance)

    on_exit(fn ->
      Application.delete_env(:aikido, :telemetry)
      Application.delete_env(:aikido, :observability)
      Aikido.Debug.reset(@test_instance)
    end)

    :ok
  end

  describe("telemetry_log_level/1") do
    test "returns default when no config set" do
      assert Aikido.Observe.Config.telemetry_log_level(nil) ==
               Aikido.Config.Defaults.telemetry_log_level()
    end

    test "reads from global config" do
      Application.put_env(:aikido, :telemetry, log_level: :info)
      assert Aikido.Observe.Config.telemetry_log_level(nil) == :info
    end

    test "falls back to default when global value is invalid" do
      Application.put_env(:aikido, :telemetry, log_level: :invalid)

      assert Aikido.Observe.Config.telemetry_log_level(nil) ==
               Aikido.Config.Defaults.telemetry_log_level()
    end

    test "nil instance skips debug override" do
      assert Aikido.Observe.Config.telemetry_log_level(nil) ==
               Aikido.Config.Defaults.telemetry_log_level()
    end
  end

  describe("telemetry_log_args/1") do
    test "returns default when no config set" do
      assert Aikido.Observe.Config.telemetry_log_args(nil) ==
               Aikido.Config.Defaults.telemetry_log_args()
    end

    test "reads from global config" do
      Application.put_env(:aikido, :telemetry, log_args: :full)
      assert Aikido.Observe.Config.telemetry_log_args(nil) == :full
    end

    test "falls back to default when value is invalid" do
      Application.put_env(:aikido, :telemetry, log_args: :verbose)

      assert Aikido.Observe.Config.telemetry_log_args(nil) ==
               Aikido.Config.Defaults.telemetry_log_args()
    end
  end

  describe("slow_signal_threshold_ms/1") do
    test "returns default" do
      assert Aikido.Observe.Config.slow_signal_threshold_ms(nil) ==
               Aikido.Config.Defaults.slow_signal_threshold_ms()
    end

    test "reads from global config" do
      Application.put_env(:aikido, :telemetry, slow_signal_threshold_ms: 50)
      assert Aikido.Observe.Config.slow_signal_threshold_ms(nil) == 50
    end

    test "falls back to default when value is invalid" do
      Application.put_env(:aikido, :telemetry, slow_signal_threshold_ms: -5)

      assert Aikido.Observe.Config.slow_signal_threshold_ms(nil) ==
               Aikido.Config.Defaults.slow_signal_threshold_ms()
    end
  end

  describe("slow_directive_threshold_ms/1") do
    test "returns default" do
      assert Aikido.Observe.Config.slow_directive_threshold_ms(nil) ==
               Aikido.Config.Defaults.slow_directive_threshold_ms()
    end

    test "falls back to default when value is invalid" do
      Application.put_env(:aikido, :telemetry, slow_directive_threshold_ms: "slow")

      assert Aikido.Observe.Config.slow_directive_threshold_ms(nil) ==
               Aikido.Config.Defaults.slow_directive_threshold_ms()
    end
  end

  describe("interesting_signal_types/1") do
    test "returns default list" do
      types = Aikido.Observe.Config.interesting_signal_types(nil)
      assert is_list(types)
    end

    test "falls back to defaults when list contains non-strings" do
      Application.put_env(:aikido, :telemetry, interesting_signal_types: ["ok", 123])

      assert Aikido.Observe.Config.interesting_signal_types(nil) ==
               Aikido.Config.Defaults.interesting_signal_types()
    end
  end

  describe("trace_enabled?/1") do
    test "false by default" do
      refute Aikido.Observe.Config.trace_enabled?(nil)
    end

    test "true when log level is trace" do
      Application.put_env(:aikido, :telemetry, log_level: :trace)
      assert Aikido.Observe.Config.trace_enabled?(nil)
    end
  end

  describe("debug_enabled?/1") do
    test "false by default (default log level is :info)" do
      refute Aikido.Observe.Config.debug_enabled?(nil)
    end

    test "false when log level is info" do
      Application.put_env(:aikido, :telemetry, log_level: :info)
      refute Aikido.Observe.Config.debug_enabled?(nil)
    end
  end

  describe("observe_log_level/1") do
    test "returns default" do
      assert Aikido.Observe.Config.observe_log_level(nil) ==
               Aikido.Config.Defaults.observe_log_level()
    end

    test "reads from global observability config" do
      Application.put_env(:aikido, :observability, log_level: :debug)
      assert Aikido.Observe.Config.observe_log_level(nil) == :debug
    end

    test "falls back to default for invalid logger level" do
      Application.put_env(:aikido, :observability, log_level: :invalid)

      assert Aikido.Observe.Config.observe_log_level(nil) ==
               Aikido.Config.Defaults.observe_log_level()
    end
  end

  describe("debug_events/1") do
    test "returns :off by default" do
      assert Aikido.Observe.Config.debug_events(nil) ==
               Aikido.Config.Defaults.observe_debug_events()
    end

    test "reads from global observability config" do
      Application.put_env(:aikido, :observability, debug_events: :all)
      assert Aikido.Observe.Config.debug_events(nil) == :all
    end

    test "falls back to default when value is invalid" do
      Application.put_env(:aikido, :observability, debug_events: :everything)

      assert Aikido.Observe.Config.debug_events(nil) ==
               Aikido.Config.Defaults.observe_debug_events()
    end
  end

  describe("debug_events_enabled?/1") do
    test "false by default" do
      refute Aikido.Observe.Config.debug_events_enabled?(nil)
    end

    test "true when debug_events is :all" do
      Application.put_env(:aikido, :observability, debug_events: :all)
      assert Aikido.Observe.Config.debug_events_enabled?(nil)
    end

    test "true when debug_events is :minimal" do
      Application.put_env(:aikido, :observability, debug_events: :minimal)
      assert Aikido.Observe.Config.debug_events_enabled?(nil)
    end
  end

  describe("redact_sensitive?/1") do
    test "false by default" do
      refute Aikido.Observe.Config.redact_sensitive?(nil)
    end

    test "reads from global observability config" do
      Application.put_env(:aikido, :observability, redact_sensitive: true)
      assert Aikido.Observe.Config.redact_sensitive?(nil)
    end
  end

  describe("tracer/1") do
    test "returns NoopTracer by default" do
      assert Aikido.Observe.Config.tracer(nil) == Aikido.Observe.NoopTracer
    end

    test "returns configured tracer when it implements the contract" do
      Application.put_env(:aikido, :observability,
        tracer: AikidoTest.Observe.ConfigTest.ValidTracer
      )

      assert Aikido.Observe.Config.tracer(nil) == AikidoTest.Observe.ConfigTest.ValidTracer
    end

    test "falls back to default tracer when configured module is invalid" do
      Application.put_env(:aikido, :observability, tracer: Date)
      assert Aikido.Observe.Config.tracer(nil) == Aikido.Config.Defaults.tracer()
    end
  end

  describe("tracer_failure_mode/1") do
    test "returns :warn by default" do
      assert Aikido.Observe.Config.tracer_failure_mode(nil) == :warn
    end

    test "reads from global observability config" do
      Application.put_env(:aikido, :observability, tracer_failure_mode: :strict)
      assert Aikido.Observe.Config.tracer_failure_mode(nil) == :strict
    end

    test "falls back to default when value is invalid" do
      Application.put_env(:aikido, :observability, tracer_failure_mode: :invalid)
      assert Aikido.Observe.Config.tracer_failure_mode(nil) == :warn
    end
  end

  describe("debug_max_events/1") do
    test "returns default by default" do
      assert Aikido.Observe.Config.debug_max_events(nil) ==
               Aikido.Config.Defaults.debug_max_events()
    end

    test "reads from global telemetry config" do
      Application.put_env(:aikido, :telemetry, debug_max_events: 1000)
      assert Aikido.Observe.Config.debug_max_events(nil) == 1000
    end

    test "falls back to default when value is invalid" do
      Application.put_env(:aikido, :telemetry, debug_max_events: -1)

      assert Aikido.Observe.Config.debug_max_events(nil) ==
               Aikido.Config.Defaults.debug_max_events()
    end
  end

  describe("level_enabled?/2") do
    test "debug is not enabled at info level" do
      refute Aikido.Observe.Config.level_enabled?(nil, :debug)
    end

    test "trace is not enabled at debug level" do
      refute Aikido.Observe.Config.level_enabled?(nil, :trace)
    end

    test "info is enabled at debug level" do
      assert Aikido.Observe.Config.level_enabled?(nil, :info)
    end
  end

  describe("interesting_signal_type?/2") do
    test "returns true for types listed in interesting_signal_types config" do
      Application.put_env(:aikido, :telemetry, interesting_signal_types: ["my.app.event"])
      on_exit(fn -> Application.delete_env(:aikido, :telemetry) end)
      assert Aikido.Observe.Config.interesting_signal_type?(nil, "my.app.event")
    end

    test "returns false for unknown types" do
      refute Aikido.Observe.Config.interesting_signal_type?(nil, "some.random.signal")
    end
  end
end
