defmodule Aikido.Observe.NoopTracer do
  @moduledoc """
  Default no-op tracer implementation.

  This tracer does nothing and is used when no external tracing backend is configured.
  All span operations return immediately without side effects.
  """

  @behaviour Aikido.Observe.Tracer

  @impl true
  @spec span_start(Aikido.Observe.Tracer.event_prefix(), Aikido.Observe.Tracer.metadata()) :: nil
  def span_start(_event_prefix, _metadata), do: nil

  @impl true
  @spec span_stop(Aikido.Observe.Tracer.tracer_ctx(), Aikido.Observe.Tracer.measurements()) :: :ok
  def span_stop(_tracer_ctx, _measurements), do: :ok

  @impl true
  @spec span_exception(Aikido.Observe.Tracer.tracer_ctx(), atom(), term(), list()) :: :ok
  def span_exception(_tracer_ctx, _kind, _reason, _stacktrace), do: :ok
end
