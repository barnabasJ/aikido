defmodule AikidoTest.ObserveCoverageTest.FailingTracer do
  @behaviour Aikido.Observe.Tracer
  def span_start(_event_prefix, _metadata) do
    raise "span_start failure"
  end

  def span_stop(_tracer_ctx, _measurements) do
    raise "span_stop failure"
  end

  def span_exception(_tracer_ctx, _kind, _reason, _stacktrace) do
    raise "span_exception failure"
  end
end

defmodule AikidoTest.ObserveCoverageTest do
  @moduledoc """
  Additional coverage tests for Aikido.Observe.

  Targets uncovered paths:
  - Tracer error logging paths (span_start, span_stop, span_exception failures)
  - debug_enabled?/0 with various config values
  - emit_event/3 and emit_debug_event/3 behavior
  - redact/2 with various config scenarios
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    original_config = Application.get_env(:aikido, :observability)

    on_exit(fn ->
      Logger.configure(level: previous_level)

      if original_config do
        Application.put_env(:aikido, :observability, original_config)
      else
        Application.delete_env(:aikido, :observability)
      end
    end)

    :ok
  end

  describe("tracer error handling") do
    nil

    test "logs warning when span_start fails" do
      Application.put_env(:aikido, :observability,
        tracer: AikidoTest.ObserveCoverageTest.FailingTracer
      )

      log =
        capture_log(fn ->
          _span_ctx = Aikido.Observe.start_span([:aikido, :test, :failing], %{})
        end)

      assert log =~ "Aikido.Observe tracer span_start/2 failed"
      assert log =~ "span_start failure"
    end

    test "logs warning when span_stop fails" do
      Application.put_env(:aikido, :observability,
        tracer: AikidoTest.ObserveCoverageTest.FailingTracer
      )

      log =
        capture_log(fn ->
          span_ctx = Aikido.Observe.start_span([:aikido, :test, :failing], %{})
          Aikido.Observe.finish_span(span_ctx)
        end)

      assert log =~ "Aikido.Observe tracer span_stop/2 failed"
      assert log =~ "span_stop failure"
    end

    test "logs warning when span_exception fails" do
      Application.put_env(:aikido, :observability,
        tracer: AikidoTest.ObserveCoverageTest.FailingTracer
      )

      log =
        capture_log(fn ->
          span_ctx = Aikido.Observe.start_span([:aikido, :test, :failing], %{})
          Aikido.Observe.finish_span_error(span_ctx, :error, :some_error, [])
        end)

      assert log =~ "Aikido.Observe tracer span_exception/4 failed"
      assert log =~ "span_exception failure"
    end

    test "with_span re-raises after tracer failure on exception" do
      Application.put_env(:aikido, :observability,
        tracer: AikidoTest.ObserveCoverageTest.FailingTracer
      )

      log =
        capture_log(fn ->
          assert_raise RuntimeError, "original error", fn ->
            Aikido.Observe.with_span([:aikido, :test, :failing], %{}, fn ->
              raise "original error"
            end)
          end
        end)

      assert log =~ "span_exception failure"
    end
  end

  describe("debug_enabled?/0") do
    test "returns false when debug_events is :off" do
      Application.put_env(:aikido, :observability, debug_events: :off)
      refute Aikido.Observe.debug_enabled?()
    end

    test "returns false when debug_events is nil (not configured)" do
      Application.put_env(:aikido, :observability, [])
      refute Aikido.Observe.debug_enabled?()
    end

    test "returns false when observability config is not set" do
      Application.delete_env(:aikido, :observability)
      refute Aikido.Observe.debug_enabled?()
    end

    test "returns true when debug_events is :all" do
      Application.put_env(:aikido, :observability, debug_events: :all)
      assert Aikido.Observe.debug_enabled?()
    end

    test "returns true when debug_events is :minimal" do
      Application.put_env(:aikido, :observability, debug_events: :minimal)
      assert Aikido.Observe.debug_enabled?()
    end
  end

  describe("emit_debug_event/3") do
    setup do
      Aikido.Tracing.Context.clear()
      test_pid = self()
      handler_id = "debug-event-handler-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:aikido, :test, :debug],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:debug_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        Aikido.Tracing.Context.clear()
        :telemetry.detach(handler_id)
      end)

      :ok
    end

    test "enriches debug metadata with trace correlation when present" do
      Application.put_env(:aikido, :observability, debug_events: :all)
      signal = Jido.Signal.new!("test.debug.trace", %{}, source: "/test")
      {_traced_signal, trace} = Aikido.Tracing.Context.ensure_from_signal(signal)
      Aikido.Observe.emit_debug_event([:aikido, :test, :debug], %{count: 5}, %{key: "trace"})
      assert_receive {:debug_event, [:aikido, :test, :debug], %{count: 5}, metadata}
      assert metadata.key == "trace"
      assert metadata.aikido_trace_id == trace.trace_id
      assert metadata.aikido_span_id == trace.span_id
    end

    test "emits event when debug_events is :all" do
      Application.put_env(:aikido, :observability, debug_events: :all)
      Aikido.Observe.emit_debug_event([:aikido, :test, :debug], %{count: 1}, %{key: "value"})
      assert_receive {:debug_event, [:aikido, :test, :debug], %{count: 1}, %{key: "value"}}
    end

    test "emits event when debug_events is :minimal" do
      Application.put_env(:aikido, :observability, debug_events: :minimal)
      Aikido.Observe.emit_debug_event([:aikido, :test, :debug], %{count: 2}, %{key: "minimal"})
      assert_receive {:debug_event, [:aikido, :test, :debug], %{count: 2}, %{key: "minimal"}}
    end

    test "does not emit event when debug_events is :off" do
      Application.put_env(:aikido, :observability, debug_events: :off)
      Aikido.Observe.emit_debug_event([:aikido, :test, :debug], %{count: 3}, %{key: "off"})
      refute_receive {:debug_event, _, _, _}, 10
    end

    test "does not emit event when debug_events is not configured" do
      Application.put_env(:aikido, :observability, [])
      Aikido.Observe.emit_debug_event([:aikido, :test, :debug], %{count: 4}, %{key: "none"})
      refute_receive {:debug_event, _, _, _}, 10
    end

    test "returns :ok regardless of debug state" do
      Application.put_env(:aikido, :observability, debug_events: :off)
      assert Aikido.Observe.emit_debug_event([:aikido, :test, :debug]) == :ok
      Application.put_env(:aikido, :observability, debug_events: :all)
      assert Aikido.Observe.emit_debug_event([:aikido, :test, :debug]) == :ok
    end

    test "works with default empty measurements and metadata" do
      Application.put_env(:aikido, :observability, debug_events: :all)
      Aikido.Observe.emit_debug_event([:aikido, :test, :debug])
      assert_receive {:debug_event, [:aikido, :test, :debug], %{}, %{}}
    end
  end

  describe("emit_event/3") do
    setup do
      Aikido.Tracing.Context.clear()
      test_pid = self()
      handler_id = "event-handler-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:aikido, :test, :event],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        Aikido.Tracing.Context.clear()
        :telemetry.detach(handler_id)
      end)

      :ok
    end

    test "emits event regardless of debug_events config" do
      Application.put_env(:aikido, :observability, debug_events: :off)
      Aikido.Observe.emit_event([:aikido, :test, :event], %{count: 1}, %{key: "value"})
      assert_receive {:event, [:aikido, :test, :event], %{count: 1}, %{key: "value"}}
    end

    test "returns :ok and supports default measurements and metadata" do
      assert Aikido.Observe.emit_event([:aikido, :test, :event]) == :ok
      assert_receive {:event, [:aikido, :test, :event], %{}, %{}}
    end

    test "enriches metadata with current trace context" do
      signal = Jido.Signal.new!("test.event.trace", %{}, source: "/test")
      {_traced_signal, trace} = Aikido.Tracing.Context.ensure_from_signal(signal)
      Aikido.Observe.emit_event([:aikido, :test, :event], %{count: 2}, %{key: "trace"})
      assert_receive {:event, [:aikido, :test, :event], %{count: 2}, metadata}
      assert metadata.key == "trace"
      assert metadata.aikido_trace_id == trace.trace_id
      assert metadata.aikido_span_id == trace.span_id
    end

    test "caller metadata takes precedence over correlation metadata" do
      signal = Jido.Signal.new!("test.event.override", %{}, source: "/test")
      {_traced_signal, trace} = Aikido.Tracing.Context.ensure_from_signal(signal)
      custom_trace_id = "custom-trace-id"

      Aikido.Observe.emit_event([:aikido, :test, :event], %{}, %{aikido_trace_id: custom_trace_id})

      assert_receive {:event, [:aikido, :test, :event], %{}, metadata}
      assert metadata.aikido_trace_id == custom_trace_id
      assert metadata.aikido_span_id == trace.span_id
    end
  end

  describe("redact/2") do
    test "returns value unchanged when redact_sensitive is false" do
      Application.put_env(:aikido, :observability, redact_sensitive: false)
      assert Aikido.Observe.redact("secret data") == "secret data"
    end

    test "returns [REDACTED] when redact_sensitive is true" do
      Application.put_env(:aikido, :observability, redact_sensitive: true)
      assert Aikido.Observe.redact("secret data") == "[REDACTED]"
    end

    test "returns value unchanged when redact_sensitive is not configured" do
      Application.put_env(:aikido, :observability, [])
      assert Aikido.Observe.redact("secret data") == "secret data"
    end

    test "returns value unchanged when observability config is not set" do
      Application.delete_env(:aikido, :observability)
      assert Aikido.Observe.redact("secret data") == "secret data"
    end

    test "force_redact: true always redacts regardless of config" do
      Application.put_env(:aikido, :observability, redact_sensitive: false)
      assert Aikido.Observe.redact("secret data", force_redact: true) == "[REDACTED]"
    end

    test "force_redact: false respects config" do
      Application.put_env(:aikido, :observability, redact_sensitive: true)
      assert Aikido.Observe.redact("secret data", force_redact: false) == "[REDACTED]"
      Application.put_env(:aikido, :observability, redact_sensitive: false)
      assert Aikido.Observe.redact("secret data", force_redact: false) == "secret data"
    end

    test "redacts various data types" do
      Application.put_env(:aikido, :observability, redact_sensitive: true)
      assert Aikido.Observe.redact(12345) == "[REDACTED]"
      assert Aikido.Observe.redact(%{key: "value"}) == "[REDACTED]"
      assert Aikido.Observe.redact([:a, :b, :c]) == "[REDACTED]"
      assert Aikido.Observe.redact(nil) == "[REDACTED]"
    end
  end

  describe("custom tracer with TestTracer") do
    setup do
      {:ok, _pid} = AikidoTest.Support.TestTracer.start_link()
      AikidoTest.Support.TestTracer.clear()
      Application.put_env(:aikido, :observability, tracer: AikidoTest.Support.TestTracer)
      :ok
    end

    test "records span_start, span_stop through TestTracer" do
      span_ctx = Aikido.Observe.start_span([:aikido, :tracer, :test], %{key: "val"})
      Aikido.Observe.finish_span(span_ctx, %{extra: 123})
      spans = AikidoTest.Support.TestTracer.get_spans()

      assert Enum.any?(spans, fn
               {:start, _ref, [:aikido, :tracer, :test], %{key: "val"}} -> true
               _ -> false
             end)

      assert Enum.any?(spans, fn
               {:stop, _ref, %{duration: _, extra: 123}} -> true
               _ -> false
             end)
    end

    test "records span_exception through TestTracer" do
      span_ctx = Aikido.Observe.start_span([:aikido, :tracer, :exception], %{})
      Aikido.Observe.finish_span_error(span_ctx, :error, :test_error, [])
      spans = AikidoTest.Support.TestTracer.get_spans()

      assert Enum.any?(spans, fn
               {:exception, _ref, :error, :test_error, []} -> true
               _ -> false
             end)
    end
  end

  describe("with_span catch clause") do
    setup do
      test_pid = self()
      handler_id = "catch-handler-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:aikido, :test, :catch, :exception],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:exception_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "handles exit signals and re-exits" do
      Application.put_env(:aikido, :observability, tracer: Aikido.Observe.NoopTracer)

      assert catch_exit(
               Aikido.Observe.with_span([:aikido, :test, :catch], %{exit_test: true}, fn ->
                 exit(:test_exit_value)
               end)
             ) == :test_exit_value

      assert_receive {:exception_event, [:aikido, :test, :catch, :exception], %{duration: _},
                      %{kind: :exit, error: :test_exit_value}}
    end
  end
end
