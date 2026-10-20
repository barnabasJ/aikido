defmodule AikidoTest.ObserveTest do
  @moduledoc """
  Tests for Aikido.Observe façade and related modules.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup do
    previous_level = Logger.level()
    previous_observability = Application.get_env(:aikido, :observability)
    Application.delete_env(:aikido, :observability)

    on_exit(fn ->
      if previous_observability,
        do: Application.put_env(:aikido, :observability, previous_observability),
        else: Application.delete_env(:aikido, :observability)
    end)

    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  describe("with_span/3") do
    setup do
      test_pid = self()
      handler_id = "test-handler-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:aikido, :test, :with_span, :start],
          [:aikido, :test, :with_span, :stop],
          [:aikido, :test, :with_span, :exception]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits :start and :stop telemetry events" do
      result =
        Aikido.Observe.with_span([:aikido, :test, :with_span], %{key: "value"}, fn -> :success end)

      assert result == :success

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :start], %{system_time: st},
                      %{key: "value"}}

      assert is_integer(st)

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :stop],
                      %{duration: duration}, %{key: "value"}}

      assert is_integer(duration)
      assert duration >= 0
    end

    test "returns the function's return value" do
      result =
        Aikido.Observe.with_span([:aikido, :test, :with_span], %{}, fn ->
          {:ok, %{data: [1, 2, 3]}}
        end)

      assert result == {:ok, %{data: [1, 2, 3]}}
    end

    test "measures duration correctly" do
      sleep_time_ms = 10

      Aikido.Observe.with_span([:aikido, :test, :with_span], %{}, fn ->
        Process.sleep(sleep_time_ms)
      end)

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :start], _, _}

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :stop],
                      %{duration: duration}, _}

      duration_ms = div(duration, 1_000_000)
      assert duration_ms >= sleep_time_ms
    end

    test "emits :exception event on error and re-raises" do
      assert_raise RuntimeError, "test error", fn ->
        Aikido.Observe.with_span([:aikido, :test, :with_span], %{error_test: true}, fn ->
          raise "test error"
        end)
      end

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :start], _,
                      %{error_test: true}}

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :exception],
                      %{duration: duration}, metadata}

      assert is_integer(duration)
      assert duration >= 0
      assert metadata.error_test == true
      assert metadata.kind == :error
      assert %RuntimeError{message: "test error"} = metadata.error
      assert is_list(metadata.stacktrace)
    end

    test "emits :exception event on throw and re-throws" do
      assert catch_throw(
               Aikido.Observe.with_span([:aikido, :test, :with_span], %{throw_test: true}, fn ->
                 throw(:my_throw)
               end)
             ) == :my_throw

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :start], _,
                      %{throw_test: true}}

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :exception], %{duration: _},
                      metadata}

      assert metadata.kind == :throw
      assert metadata.error == :my_throw
    end

    test "emits :exception event on exit and re-exits" do
      assert catch_exit(
               Aikido.Observe.with_span([:aikido, :test, :with_span], %{exit_test: true}, fn ->
                 exit(:my_exit)
               end)
             ) == :my_exit

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :start], _,
                      %{exit_test: true}}

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :exception], %{duration: _},
                      metadata}

      assert metadata.kind == :exit
      assert metadata.error == :my_exit
    end

    test "passes metadata to all events" do
      metadata = %{agent_id: "agent-123", step: 5, model: "claude"}
      Aikido.Observe.with_span([:aikido, :test, :with_span], metadata, fn -> :ok end)

      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :start], _,
                      received_metadata}

      assert received_metadata == metadata
      assert_receive {:telemetry_event, [:aikido, :test, :with_span, :stop], _, received_metadata}
      assert received_metadata == metadata
    end
  end

  describe("start_span/2 and finish_span/2") do
    setup do
      test_pid = self()
      handler_id = "test-handler-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [[:aikido, :test, :manual_span, :start], [:aikido, :test, :manual_span, :stop]],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits :start event on start_span" do
      _span_ctx = Aikido.Observe.start_span([:aikido, :test, :manual_span], %{key: "start_value"})

      assert_receive {:telemetry_event, [:aikido, :test, :manual_span, :start],
                      %{system_time: st}, %{key: "start_value"}}

      assert is_integer(st)
    end

    test "emits :stop event on finish_span" do
      span_ctx = Aikido.Observe.start_span([:aikido, :test, :manual_span], %{key: "stop_value"})
      result = Aikido.Observe.finish_span(span_ctx)
      assert result == :ok
      assert_receive {:telemetry_event, [:aikido, :test, :manual_span, :start], _, _}

      assert_receive {:telemetry_event, [:aikido, :test, :manual_span, :stop],
                      %{duration: duration}, %{key: "stop_value"}}

      assert is_integer(duration)
      assert duration >= 0
    end

    test "includes extra_measurements in stop event" do
      span_ctx = Aikido.Observe.start_span([:aikido, :test, :manual_span], %{})
      extra = %{prompt_tokens: 100, completion_tokens: 50, total_tokens: 150}
      Aikido.Observe.finish_span(span_ctx, extra)
      assert_receive {:telemetry_event, [:aikido, :test, :manual_span, :stop], measurements, _}
      assert measurements.duration >= 0
      assert measurements.prompt_tokens == 100
      assert measurements.completion_tokens == 50
      assert measurements.total_tokens == 150
    end

    test "duration is measured correctly" do
      sleep_time_ms = 10
      span_ctx = Aikido.Observe.start_span([:aikido, :test, :manual_span], %{})
      Process.sleep(sleep_time_ms)
      Aikido.Observe.finish_span(span_ctx)

      assert_receive {:telemetry_event, [:aikido, :test, :manual_span, :stop],
                      %{duration: duration}, _}

      duration_ms = div(duration, 1_000_000)
      assert duration_ms >= sleep_time_ms
    end

    test "returns span context struct with required keys" do
      span_ctx = Aikido.Observe.start_span([:aikido, :test, :manual_span], %{meta: "data"})
      assert %Aikido.Observe.SpanCtx{} = span_ctx
      assert span_ctx.event_prefix == [:aikido, :test, :manual_span]
      assert span_ctx.metadata == %{meta: "data"}
      assert is_integer(span_ctx.start_time)
      assert is_integer(span_ctx.start_system_time)
      assert span_ctx.tracer_module == nil
    end
  end

  describe("finish_span_error/4") do
    setup do
      test_pid = self()
      handler_id = "test-handler-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [[:aikido, :test, :error_span, :start], [:aikido, :test, :error_span, :exception]],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits :exception event" do
      span_ctx = Aikido.Observe.start_span([:aikido, :test, :error_span], %{})

      result =
        Aikido.Observe.finish_span_error(span_ctx, :error, %RuntimeError{message: "boom"}, [
          {__MODULE__, :test, 0, []}
        ])

      assert result == :ok

      assert_receive {:telemetry_event, [:aikido, :test, :error_span, :exception], %{duration: _},
                      _}
    end

    test "includes kind, error, stacktrace in metadata" do
      span_ctx = Aikido.Observe.start_span([:aikido, :test, :error_span], %{original: "meta"})
      error = %ArgumentError{message: "invalid argument"}
      stacktrace = [{__MODULE__, :some_fun, 2, file: ~c"test.ex", line: 42}]
      Aikido.Observe.finish_span_error(span_ctx, :error, error, stacktrace)

      assert_receive {:telemetry_event, [:aikido, :test, :error_span, :exception], %{duration: _},
                      metadata}

      assert metadata.original == "meta"
      assert metadata.kind == :error
      assert metadata.error == error
      assert metadata.stacktrace == stacktrace
    end

    test "supports different error kinds" do
      for kind <- [:error, :exit, :throw] do
        span_ctx = Aikido.Observe.start_span([:aikido, :test, :error_span], %{})
        Aikido.Observe.finish_span_error(span_ctx, kind, :some_reason, [])

        assert_receive {:telemetry_event, [:aikido, :test, :error_span, :exception], _,
                        %{kind: ^kind}}
      end
    end

    test "measures duration correctly" do
      sleep_time_ms = 10
      span_ctx = Aikido.Observe.start_span([:aikido, :test, :error_span], %{})
      Process.sleep(sleep_time_ms)
      Aikido.Observe.finish_span_error(span_ctx, :error, :some_error, [])

      assert_receive {:telemetry_event, [:aikido, :test, :error_span, :exception],
                      %{duration: duration}, _}

      duration_ms = div(duration, 1_000_000)
      assert duration_ms >= sleep_time_ms
    end
  end

  describe("emit_event/3") do
    setup do
      Aikido.Tracing.Context.clear()
      test_pid = self()
      handler_id = "emit-event-handler-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:aikido, :test, :domain, :event],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        Aikido.Tracing.Context.clear()
        :telemetry.detach(handler_id)
      end)

      :ok
    end

    test "emits event even when debug events are off" do
      Application.put_env(:aikido, :observability, debug_events: :off)

      assert :ok =
               Aikido.Observe.emit_event(
                 [:aikido, :test, :domain, :event],
                 %{duration_ms: 12},
                 %{request_id: "req-1"}
               )

      assert_receive {:telemetry_event, [:aikido, :test, :domain, :event], %{duration_ms: 12},
                      %{request_id: "req-1"}}
    end

    test "enriches metadata with active trace context" do
      signal = Jido.Signal.new!("trace.source", %{}, source: "/test")
      {_traced_signal, trace} = Aikido.Tracing.Context.ensure_from_signal(signal)
      Aikido.Observe.emit_event([:aikido, :test, :domain, :event], %{count: 1}, %{phase: :tool})
      assert_receive {:telemetry_event, [:aikido, :test, :domain, :event], %{count: 1}, metadata}
      assert metadata.phase == :tool
      assert metadata.aikido_trace_id == trace.trace_id
      assert metadata.aikido_span_id == trace.span_id
    end

    test "caller metadata overrides correlation metadata keys" do
      signal = Jido.Signal.new!("trace.override", %{}, source: "/test")
      {_traced_signal, trace} = Aikido.Tracing.Context.ensure_from_signal(signal)

      Aikido.Observe.emit_event([:aikido, :test, :domain, :event], %{}, %{
        aikido_trace_id: "custom-trace"
      })

      assert_receive {:telemetry_event, [:aikido, :test, :domain, :event], %{}, metadata}
      assert metadata.aikido_trace_id == "custom-trace"
      assert metadata.aikido_span_id == trace.span_id
    end
  end

  describe("log/3") do
    setup do
      original_config = Application.get_env(:aikido, :observability)

      on_exit(fn ->
        if original_config do
          Application.put_env(:aikido, :observability, original_config)
        else
          Application.delete_env(:aikido, :observability)
        end
      end)

      :ok
    end

    test "delegates to Aikido.Observe.Log" do
      Application.put_env(:aikido, :observability, log_level: :debug)
      log = capture_log(fn -> Aikido.Observe.log(:info, "test message", key: "value") end)
      assert log =~ "test message"
    end
  end

  describe("Aikido.Observe.Log.threshold/0") do
    setup do
      original_config = Application.get_env(:aikido, :observability)

      on_exit(fn ->
        if original_config do
          Application.put_env(:aikido, :observability, original_config)
        else
          Application.delete_env(:aikido, :observability)
        end
      end)

      :ok
    end

    test "returns configured value" do
      Application.put_env(:aikido, :observability, log_level: :warning)
      assert Aikido.Observe.Log.threshold() == :warning
      Application.put_env(:aikido, :observability, log_level: :debug)
      assert Aikido.Observe.Log.threshold() == :debug
    end

    test "defaults to :info when not configured" do
      Application.delete_env(:aikido, :observability)
      assert Aikido.Observe.Log.threshold() == :info
    end

    test "defaults to :info when log_level key is missing" do
      Application.put_env(:aikido, :observability, tracer: SomeTracer)
      assert Aikido.Observe.Log.threshold() == :info
    end
  end

  describe("Aikido.Observe.Log.log/3") do
    setup do
      original_config = Application.get_env(:aikido, :observability)

      on_exit(fn ->
        if original_config do
          Application.put_env(:aikido, :observability, original_config)
        else
          Application.delete_env(:aikido, :observability)
        end
      end)

      :ok
    end

    test "logs when message level meets threshold" do
      Application.put_env(:aikido, :observability, log_level: :info)
      log = capture_log(fn -> Aikido.Observe.Log.log(:info, "info message") end)
      assert log =~ "info message"
    end

    test "logs when message level exceeds threshold" do
      Application.put_env(:aikido, :observability, log_level: :info)
      log = capture_log(fn -> Aikido.Observe.Log.log(:warning, "warning message") end)
      assert log =~ "warning message"
    end

    test "does not log when message level is below threshold" do
      Application.put_env(:aikido, :observability, log_level: :warning)

      log =
        capture_log(fn ->
          Aikido.Observe.Log.log(:debug, "debug message")
          Aikido.Observe.Log.log(:info, "info message")
        end)

      refute log =~ "debug message"
      refute log =~ "info message"
    end

    test "includes metadata in log output" do
      Application.put_env(:aikido, :observability, log_level: :debug)

      log =
        capture_log(fn ->
          Aikido.Observe.Log.log(:info, "with metadata", agent_id: "agent-123")
        end)

      assert log =~ "with metadata"
    end

    test "logs at debug level when threshold is debug" do
      Application.put_env(:aikido, :observability, log_level: :debug)
      log = capture_log(fn -> Aikido.Observe.Log.log(:debug, "debug level message") end)
      assert log =~ "debug level message"
    end
  end

  describe "native Ash tracer integration" do
    setup do
      start_supervised!(AikidoTest.Support.TestTracer)
      Application.put_env(:aikido, :observability, tracer: AikidoTest.Support.TestTracer)
      :ok
    end

    test "executes work once and retains span context across nested operations" do
      tracer = AikidoTest.Support.TestTracer

      assert :result =
               Aikido.Observe.with_span([:aikido, :outer], %{test: true}, fn ->
                 outer = tracer.get_span_context()
                 assert is_reference(outer)

                 Aikido.Observe.with_span([:aikido, :inner], %{}, fn ->
                   refute tracer.get_span_context() == outer
                 end)

                 assert tracer.get_span_context() == outer
                 :result
               end)

      assert tracer.get_span_context() == nil
      spans = tracer.get_spans()
      assert Enum.count(spans, &match?({:stop, _}, &1)) == 2
      assert Enum.any?(spans, &match?({:start, _, {:custom, :aikido}, "aikido.outer"}, &1))
    end

    test "reports errors and preserves the original exception" do
      assert_raise RuntimeError, "failure", fn ->
        Aikido.Observe.with_span([:aikido, :failed], %{}, fn -> raise "failure" end)
      end

      assert Enum.any?(
               AikidoTest.Support.TestTracer.get_spans(),
               &match?({:exception, _, %RuntimeError{}, _}, &1)
             )
    end
  end
end
