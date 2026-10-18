defmodule AikidoTest.Observe.TracerScopeContractTest.ScopedTracer do
  @behaviour Aikido.Observe.Tracer
  @impl true
  def span_start(_event_prefix, _metadata) do
    send(self(), :legacy_start)
    :legacy_ctx
  end

  @impl true
  def span_stop(_ctx, _measurements) do
    send(self(), :legacy_stop)
    :ok
  end

  @impl true
  def span_exception(_ctx, _kind, _reason, _stacktrace) do
    send(self(), :legacy_exception)
    :ok
  end

  @impl true
  def with_span_scope(event_prefix, metadata, fun) do
    send(self(), {:scoped_called, event_prefix, metadata})
    fun.()
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest.LegacyTracer do
  @behaviour Aikido.Observe.Tracer
  @impl true
  def span_start(event_prefix, metadata) do
    send(self(), {:legacy_start, event_prefix, metadata})
    :legacy_ctx
  end

  @impl true
  def span_stop(ctx, measurements) do
    send(self(), {:legacy_stop, ctx, measurements})
    :ok
  end

  @impl true
  def span_exception(ctx, kind, reason, stacktrace) do
    send(self(), {:legacy_exception, ctx, kind, reason, stacktrace})
    :ok
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest.ZeroInvokeTracer do
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

  @impl true
  def with_span_scope(_event_prefix, _metadata, _fun) do
    :ignored
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest.DoubleInvokeTracer do
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

  @impl true
  def with_span_scope(_event_prefix, _metadata, fun) do
    first = fun.()
    _second = fun.()
    first
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest.TamperTracer do
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

  @impl true
  def with_span_scope(_event_prefix, _metadata, fun) do
    _ = fun.()
    :tampered
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest.SwallowTracer do
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

  @impl true
  def with_span_scope(_event_prefix, _metadata, fun) do
    fun.()
  rescue
    _ -> :swallowed
  catch
    _, _ -> :swallowed
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest.ScopeThrowTracer do
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

  @impl true
  def with_span_scope(_event_prefix, _metadata, _fun) do
    throw(:scope_failure)
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest.CrossProcessInvokeTracer do
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

  @impl true
  def with_span_scope(_event_prefix, _metadata, fun) do
    caller = self()
    ref = make_ref()

    spawn(fn ->
      result =
        try do
          {:ok, fun.()}
        rescue
          e -> {:error, e, __STACKTRACE__}
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        end

      send(caller, {ref, result})
    end)

    receive do
      {^ref, {:ok, result}} -> result
      {^ref, {:error, error, stacktrace}} -> reraise error, stacktrace
      {^ref, {kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
    end
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest.PinnedTracerA do
  @behaviour Aikido.Observe.Tracer
  @impl true
  def span_start(_event_prefix, _metadata) do
    send(self(), :a_start)
    :a_ctx
  end

  @impl true
  def span_stop(ctx, measurements) do
    send(self(), {:a_stop, ctx, measurements})
    :ok
  end

  @impl true
  def span_exception(ctx, kind, reason, stacktrace) do
    send(self(), {:a_exception, ctx, kind, reason, stacktrace})
    :ok
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest.PinnedTracerB do
  @behaviour Aikido.Observe.Tracer
  @impl true
  def span_start(_event_prefix, _metadata) do
    send(self(), :b_start)
    :b_ctx
  end

  @impl true
  def span_stop(ctx, measurements) do
    send(self(), {:b_stop, ctx, measurements})
    :ok
  end

  @impl true
  def span_exception(ctx, kind, reason, stacktrace) do
    send(self(), {:b_exception, ctx, kind, reason, stacktrace})
    :ok
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest.ThrowingFinishTracer do
  @behaviour Aikido.Observe.Tracer
  @impl true
  def span_start(_event_prefix, _metadata) do
    :finish_ctx
  end

  @impl true
  def span_stop(_ctx, _measurements) do
    throw(:stop_throw)
  end

  @impl true
  def span_exception(_ctx, _kind, _reason, _stacktrace) do
    exit(:exception_exit)
  end
end

defmodule AikidoTest.Observe.TracerScopeContractTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

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

  test "with_span/3 uses with_span_scope/3 when implemented" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.ScopedTracer
    )

    assert :ok =
             Aikido.Observe.with_span([:aikido, :scope, :used], %{mode: :scoped}, fn -> :ok end)

    assert_receive {:scoped_called, [:aikido, :scope, :used], %{mode: :scoped}}
    refute_receive :legacy_start, 10
    refute_receive :legacy_stop, 10
    refute_receive :legacy_exception, 10
  end

  test "with_span/3 falls back to legacy callbacks when scoped callback is missing" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.LegacyTracer
    )

    assert :ok =
             Aikido.Observe.with_span([:aikido, :scope, :legacy], %{mode: :legacy}, fn -> :ok end)

    assert_receive {:legacy_start, [:aikido, :scope, :legacy], %{mode: :legacy}}
    assert_receive {:legacy_stop, :legacy_ctx, %{duration: _}}
  end

  test "warn mode executes wrapped function when scoped callback never invokes it" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.ZeroInvokeTracer
    )

    log =
      capture_log(fn ->
        assert :expected =
                 Aikido.Observe.with_span([:aikido, :scope, :zero], %{}, fn -> :expected end)
      end)

    assert log =~ "with_span_scope/3 contract violation"
    assert log =~ "did not invoke wrapped function"
  end

  test "strict mode raises when scoped callback never invokes wrapped function" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.ZeroInvokeTracer,
      tracer_failure_mode: :strict
    )

    assert_raise RuntimeError, ~r/did not invoke wrapped function/, fn ->
      Aikido.Observe.with_span([:aikido, :scope, :zero, :strict], %{}, fn -> :ok end)
    end
  end

  test "warn mode preserves first invocation result when scoped callback calls wrapped function twice" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.DoubleInvokeTracer
    )

    log =
      capture_log(fn ->
        assert :first =
                 Aikido.Observe.with_span([:aikido, :scope, :double], %{}, fn -> :first end)
      end)

    assert log =~ "invoked wrapped function more than once"
  end

  test "strict mode raises when scoped callback calls wrapped function twice" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.DoubleInvokeTracer,
      tracer_failure_mode: :strict
    )

    assert_raise RuntimeError, ~r/strict mode rejected scoped callback contract violations/, fn ->
      Aikido.Observe.with_span([:aikido, :scope, :double, :strict], %{}, fn -> :ok end)
    end
  end

  test "warn mode preserves wrapped function return value when callback tampers with return" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.TamperTracer
    )

    log =
      capture_log(fn ->
        assert {:ok, :expected} =
                 Aikido.Observe.with_span([:aikido, :scope, :tamper], %{}, fn ->
                   {:ok, :expected}
                 end)
      end)

    assert log =~ "did not preserve wrapped function return value"
  end

  test "strict mode raises when callback tampers with return" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.TamperTracer,
      tracer_failure_mode: :strict
    )

    assert_raise RuntimeError, ~r/strict mode rejected scoped callback contract violations/, fn ->
      Aikido.Observe.with_span([:aikido, :scope, :tamper, :strict], %{}, fn -> :ok end)
    end
  end

  test "swallowed error is re-raised from wrapped function" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.SwallowTracer
    )

    log =
      capture_log(fn ->
        assert_raise RuntimeError, "scope boom", fn ->
          Aikido.Observe.with_span([:aikido, :scope, :swallow, :error], %{}, fn ->
            raise "scope boom"
          end)
        end
      end)

    assert log =~ "swallowed wrapped function exception"
  end

  test "swallowed throw is re-thrown from wrapped function" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.SwallowTracer
    )

    assert catch_throw(
             Aikido.Observe.with_span([:aikido, :scope, :swallow, :throw], %{}, fn ->
               throw(:scope_throw)
             end)
           ) == :scope_throw
  end

  test "swallowed exit is re-exited from wrapped function" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.SwallowTracer
    )

    assert catch_exit(
             Aikido.Observe.with_span([:aikido, :scope, :swallow, :exit], %{}, fn ->
               exit(:scope_exit)
             end)
           ) == :scope_exit
  end

  test "warn mode falls back to wrapped function when scoped callback throws before invocation" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.ScopeThrowTracer
    )

    log =
      capture_log(fn ->
        assert :ok =
                 Aikido.Observe.with_span([:aikido, :scope, :throw, :warn], %{}, fn -> :ok end)
      end)

    assert log =~ "tracer with_span_scope/3 failed"
    assert log =~ "scope_failure"
  end

  test "warn mode prevents cross-process scoped invocation from double-running function" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.CrossProcessInvokeTracer
    )

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(counter) do
        Agent.stop(counter)
      end
    end)

    log =
      capture_log(fn ->
        assert :ok =
                 Aikido.Observe.with_span([:aikido, :scope, :cross_process, :warn], %{}, fn ->
                   Agent.update(counter, &(&1 + 1))
                   :ok
                 end)
      end)

    assert Agent.get(counter, & &1) == 1
    assert log =~ "with_span_scope/3 must execute wrapped function in caller process"
  end

  test "strict mode raises when scoped callback throws before invocation" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.ScopeThrowTracer,
      tracer_failure_mode: :strict
    )

    assert_raise RuntimeError, ~r/tracer with_span_scope\/3 failed/, fn ->
      Aikido.Observe.with_span([:aikido, :scope, :throw, :strict], %{}, fn -> :ok end)
    end
  end

  test "strict mode raises and does not run wrapped function when scoped callback runs cross-process" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.CrossProcessInvokeTracer,
      tracer_failure_mode: :strict
    )

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(counter) do
        Agent.stop(counter)
      end
    end)

    assert_raise RuntimeError, ~r/tracer with_span_scope\/3 failed/, fn ->
      Aikido.Observe.with_span([:aikido, :scope, :cross_process, :strict], %{}, fn ->
        Agent.update(counter, &(&1 + 1))
        :ok
      end)
    end

    assert Agent.get(counter, & &1) == 0
  end

  test "finish_span uses tracer pinned at start even if config changes" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.PinnedTracerA
    )

    span_ctx = Aikido.Observe.start_span([:aikido, :scope, :pinned], %{})

    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.PinnedTracerB
    )

    assert :ok = Aikido.Observe.finish_span(span_ctx)
    assert_receive :a_start
    assert_receive {:a_stop, :a_ctx, %{duration: _}}
    refute_receive {:b_stop, _, _}, 10
  end

  test "warn mode isolates throw/exit in finish callbacks" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.ThrowingFinishTracer
    )

    log =
      capture_log(fn ->
        span_ctx = Aikido.Observe.start_span([:aikido, :scope, :finish, :warn], %{})
        assert :ok = Aikido.Observe.finish_span(span_ctx)
        error_ctx = Aikido.Observe.start_span([:aikido, :scope, :finish, :warn, :exception], %{})
        assert :ok = Aikido.Observe.finish_span_error(error_ctx, :error, :reason, [])
      end)

    assert log =~ "tracer span_stop/2 failed"
    assert log =~ "tracer span_exception/4 failed"
  end

  test "strict mode raises on throw/exit in finish callbacks" do
    Application.put_env(:aikido, :observability,
      tracer: AikidoTest.Observe.TracerScopeContractTest.ThrowingFinishTracer,
      tracer_failure_mode: :strict
    )

    stop_ctx = Aikido.Observe.start_span([:aikido, :scope, :finish, :strict], %{})

    assert_raise RuntimeError, ~r/tracer span_stop\/2 failed/, fn ->
      Aikido.Observe.finish_span(stop_ctx)
    end

    exception_ctx =
      Aikido.Observe.start_span([:aikido, :scope, :finish, :strict, :exception], %{})

    assert_raise RuntimeError, ~r/tracer span_exception\/4 failed/, fn ->
      Aikido.Observe.finish_span_error(exception_ctx, :error, :reason, [])
    end
  end
end
