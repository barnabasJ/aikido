defmodule Aikido.Observe do
  @moduledoc """
  Unified observability facade for Aikido agents.

  Wraps `:telemetry` events and `Logger` with a simple API for observing
  agent execution, action invocations, and workflow iterations.

  ## Features

  - Automatic telemetry event emission (start/stop/exception)
  - Duration measurement for all spans (nanoseconds)
  - Pluggable tracer callbacks via `Ash.Tracer`
  - Threshold-based logging via `Aikido.Observe.Log`

  Ash owns span context and ancestry. Signal and task boundaries use
  `Ash.ProcessHelpers` to transfer the configured tracers' opaque contexts.
  Signal IDs and types remain ordinary telemetry/span metadata.

  ## Configuration

      config :aikido, :observability,
        log_level: :info,
        tracer: MyApp.AshTracer

  Tracers implement `Ash.Tracer`. With no tracer configured, only telemetry is emitted.

  ## Usage

  ### Synchronous work

      Aikido.Observe.with_span([:aikido, :agent, :action, :run], %{agent_id: id, action: "my_action"}, fn ->
        # Your code here
        {:ok, result}
      end)

  ### Asynchronous work (Tasks)

      span_ctx = Aikido.Observe.start_span([:aikido, :agent, :async, :request], %{agent_id: id})

      Task.start(fn ->
        try do
          result = do_async_work()
          Aikido.Observe.finish_span(span_ctx, %{result_size: byte_size(result)})
          result
        rescue
          e ->
            Aikido.Observe.finish_span_error(span_ctx, :error, e, __STACKTRACE__)
            reraise e, __STACKTRACE__
        end
      end)

  Async lifecycle spans remain explicit and context-neutral by default. Process-local
  tracing context is not implicitly attached across process boundaries.

  ## Telemetry Events

  All spans emit standard telemetry events:

  - `event_prefix ++ [:start]` - emitted when span starts
  - `event_prefix ++ [:stop]` - emitted on successful completion
  - `event_prefix ++ [:exception]` - emitted on error

  Measurements include:
  - `:system_time` - start timestamp (nanoseconds)
  - `:duration` - elapsed time (nanoseconds, on stop/exception)
  - Any additional measurements passed to `finish_span/2`

  ## Metadata Best Practices

  Metadata should be small, identifying data (IDs, step numbers, model names), not full
  prompts/responses. For large payloads, include derived measurements (`prompt_tokens`,
  `prompt_size_bytes`) rather than the raw content.
  """

  require Logger

  alias Aikido.Observe.Config, as: ObserveConfig
  alias Aikido.Observe.Log
  alias Aikido.Observe.SpanCtx

  @type event_prefix :: [atom()]
  @type metadata :: map()
  @type measurements :: map()
  @type span_ctx :: SpanCtx.t()

  @doc """
  Wraps synchronous work with telemetry span events.

  Emits `:start` event before executing the function, then either `:stop` on
  success or `:exception` if an error is raised. Duration is automatically measured.

  ## Parameters

  - `event_prefix` - List of atoms for the telemetry event name (e.g., `[:aikido, :ai, :react, :step]`)
  - `metadata` - Map of metadata to include in all events
  - `fun` - Zero-arity function to execute

  ## Returns

  The return value of `fun`.

  ## Example

      Aikido.Observe.with_span([:aikido, :ai, :tool, :invoke], %{tool: "search"}, fn ->
        perform_search(query)
      end)
  """
  @spec with_span(event_prefix(), metadata(), (-> result)) :: result when result: term()
  def with_span(event_prefix, metadata, fun)
      when is_list(event_prefix) and is_map(metadata) and is_function(fun, 0) do
    span = start_span(event_prefix, metadata)
    previous = Ash.ProcessHelpers.get_context_for_transfer(tracer: span.tracer_module)
    Ash.ProcessHelpers.transfer_context(span.tracer_ctx)

    try do
      result = fun.()
      finish_span(span)
      result
    catch
      kind, reason ->
        finish_span_error(span, kind, reason, __STACKTRACE__)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Ash.ProcessHelpers.transfer_context(previous)
    end
  end

  @doc """
  Starts an async span for work that will complete later.

  Use this for Task-based operations where you can't use `with_span/3`.
  You must call `finish_span/2` or `finish_span_error/4` when the work completes.

  ## Parameters

  - `event_prefix` - List of atoms for the telemetry event name
  - `metadata` - Map of metadata to include in all events

  ## Returns

  A span context struct to pass to `finish_span/2` or `finish_span_error/4`.

  ## Example

      span_ctx = Aikido.Observe.start_span([:aikido, :ai, :llm, :request], %{model: "claude"})

      Task.start(fn ->
        result = do_work()
        Aikido.Observe.finish_span(span_ctx, %{output_bytes: byte_size(result)})
      end)
  """
  @spec start_span(event_prefix(), metadata()) :: span_ctx()
  def start_span(event_prefix, metadata) when is_list(event_prefix) and is_map(metadata) do
    span = init_span_ctx(event_prefix, metadata)
    previous = Ash.ProcessHelpers.get_context_for_transfer(tracer: span.tracer_module)

    try do
      Ash.Tracer.start_span(span.tracer_module, {:custom, :aikido}, Enum.join(event_prefix, "."))
      Ash.Tracer.set_metadata(span.tracer_module, {:custom, :aikido}, span.metadata)

      %{
        span
        | tracer_ctx: Ash.ProcessHelpers.get_context_for_transfer(tracer: span.tracer_module)
      }
    after
      Ash.ProcessHelpers.transfer_context(previous)
    end
  end

  @doc """
  Finishes a span successfully.

  ## Parameters

  - `span_ctx` - The span context returned by `start_span/2`
  - `extra_measurements` - Additional measurements to include (e.g., token counts)

  ## Example

      Aikido.Observe.finish_span(span_ctx, %{prompt_tokens: 100, completion_tokens: 50})
  """
  @spec finish_span(span_ctx(), measurements()) :: :ok
  def finish_span(span_ctx, extra_measurements \\ %{})

  def finish_span(%SpanCtx{} = span_ctx, extra_measurements) when is_map(extra_measurements) do
    measurements = emit_stop_event(span_ctx, extra_measurements)

    with_tracer_context(span_ctx, fn ->
      Ash.Tracer.set_metadata(span_ctx.tracer_module, {:custom, :aikido}, measurements)
      Ash.Tracer.stop_span(span_ctx.tracer_module)
    end)

    :ok
  end

  @doc """
  Finishes a span with an error.

  ## Parameters

  - `span_ctx` - The span context returned by `start_span/2`
  - `kind` - The error kind (`:error`, `:exit`, `:throw`)
  - `reason` - The error reason/exception
  - `stacktrace` - The stacktrace

  ## Example

      rescue
        e ->
          Aikido.Observe.finish_span_error(span_ctx, :error, e, __STACKTRACE__)
          reraise e, __STACKTRACE__
  """
  @spec finish_span_error(span_ctx(), atom(), term(), list()) :: :ok
  def finish_span_error(%SpanCtx{} = span_ctx, kind, reason, stacktrace) do
    emit_exception_event(span_ctx, kind, reason, stacktrace)

    with_tracer_context(span_ctx, fn ->
      Ash.Tracer.set_error(span_ctx.tracer_module, Exception.normalize(kind, reason, stacktrace),
        stacktrace: stacktrace
      )

      Ash.Tracer.stop_span(span_ctx.tracer_module)
    end)

    :ok
  end

  @doc """
  Conditionally logs a message based on the observability threshold.

  Delegates to `Aikido.Observe.Log.log/3`.

  ## Example

      Aikido.Observe.log(:debug, "Processing step", agent_id: agent.id)
  """
  @spec log(Logger.level(), Logger.message(), keyword()) :: :ok
  def log(level, message, metadata \\ []) do
    Log.log(level, message, metadata)
  end

  @doc """
  Emits a telemetry event unconditionally.

  Unlike `emit_debug_event/3`, this helper does not check debug configuration.
  It is intended for domain-level events that should always be emitted.

  Metadata is passed through unchanged; native Ash spans carry trace ancestry.

  ## Parameters

  - `event_prefix` - Telemetry event name
  - `measurements` - Map of measurements (durations, counts, etc.)
  - `metadata` - Map of metadata (agent_id, iteration, etc.)

  ## Example

      Aikido.Observe.emit_event(
        [:aikido, :agent, :workflow, :step],
        %{step_duration_ns: 1_234_567},
        %{agent_id: agent.id, step: "plan"}
      )
  """
  @spec emit_event(event_prefix(), measurements(), metadata()) :: :ok
  def emit_event(event_prefix, measurements \\ %{}, metadata \\ %{})

  def emit_event(event_prefix, measurements, metadata)
      when is_list(event_prefix) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event_prefix, measurements, metadata)
    :ok
  end

  @doc """
  Emits a debug event only if debug events are enabled in config.

  This helper checks the `:debug_events` config before emitting, ensuring
  zero overhead when debugging is disabled (production default).

  ## Configuration

      # config/dev.exs
      config :aikido, :observability,
        debug_events: :all  # or :minimal, :off

      # config/prod.exs
      config :aikido, :observability,
        debug_events: :off

  ## Parameters

  - `event_prefix` - Telemetry event name
  - `measurements` - Map of measurements (durations, counts, etc.)
  - `metadata` - Map of metadata (agent_id, iteration, etc.)

  ## Example

      Aikido.Observe.emit_debug_event(
        [:aikido, :agent, :iteration, :stop],
        %{duration: 1_234_567},
        %{agent_id: agent.id, iteration: 3, status: :awaiting_tool}
      )
  """
  @spec emit_debug_event(event_prefix(), measurements(), metadata()) :: :ok
  def emit_debug_event(event_prefix, measurements \\ %{}, metadata \\ %{}) do
    instance = Map.get(metadata, :aikido_instance)

    if ObserveConfig.debug_events_enabled?(instance) do
      emit_event(event_prefix, measurements, metadata)
    end

    :ok
  end

  @doc """
  Checks if debug events are enabled in configuration.

  ## Returns

  `true` if `:debug_events` is `:all` or `:minimal`, `false` otherwise.
  """
  @spec debug_enabled?() :: boolean()
  def debug_enabled? do
    ObserveConfig.debug_events_enabled?(nil)
  end

  @doc """
  Redacts sensitive data based on configuration.

  When `:redact_sensitive` is true (production default), replaces the value
  with `"[REDACTED]"`. Otherwise returns the value unchanged.

  ## Configuration

      # config/prod.exs
      config :aikido, :observability,
        redact_sensitive: true

      # config/dev.exs
      config :aikido, :observability,
        redact_sensitive: false

  ## Parameters

  - `value` - The value to potentially redact
  - `opts` - Optional keyword list with `:force_redact` override

  ## Examples

      # In production (redact_sensitive: true)
      redact("secret data")
      # => "[REDACTED]"

      # In development (redact_sensitive: false)
      redact("secret data")
      # => "secret data"

      # Force redaction regardless of config
      redact("secret data", force_redact: true)
      # => "[REDACTED]"
  """
  @spec redact(term(), keyword()) :: term()
  def redact(value, opts \\ []) do
    force_redact = Keyword.get(opts, :force_redact, false)
    instance = Keyword.get(opts, :aikido_instance)
    should_redact = force_redact || ObserveConfig.redact_sensitive?(instance)

    if should_redact do
      "[REDACTED]"
    else
      value
    end
  end

  defp init_span_ctx(event_prefix, metadata) do
    tracer_module = tracer(metadata)
    start_time = System.monotonic_time(:nanosecond)
    start_system_time = System.system_time(:nanosecond)

    :telemetry.execute(
      event_prefix ++ [:start],
      %{system_time: start_system_time},
      metadata
    )

    %SpanCtx{
      event_prefix: event_prefix,
      start_time: start_time,
      start_system_time: start_system_time,
      metadata: metadata,
      tracer_module: tracer_module,
      tracer_ctx: nil
    }
  end

  defp emit_stop_event(%SpanCtx{} = span_ctx, extra_measurements) do
    duration = System.monotonic_time(:nanosecond) - span_ctx.start_time
    measurements = Map.merge(%{duration: duration}, extra_measurements)

    :telemetry.execute(
      span_ctx.event_prefix ++ [:stop],
      measurements,
      span_ctx.metadata
    )

    measurements
  end

  defp emit_exception_event(%SpanCtx{} = span_ctx, kind, reason, stacktrace) do
    duration = System.monotonic_time(:nanosecond) - span_ctx.start_time

    error_metadata =
      Map.merge(span_ctx.metadata, %{
        kind: kind,
        error: reason,
        stacktrace: stacktrace
      })

    :telemetry.execute(
      span_ctx.event_prefix ++ [:exception],
      %{duration: duration},
      error_metadata
    )
  end

  defp with_tracer_context(span, fun) do
    previous = Ash.ProcessHelpers.get_context_for_transfer(tracer: span.tracer_module)
    Ash.ProcessHelpers.transfer_context(span.tracer_ctx)

    try do
      fun.()
    after
      Ash.ProcessHelpers.transfer_context(previous)
    end
  end

  defp tracer(metadata) when is_map(metadata) do
    instance = Map.get(metadata, :aikido_instance)

    case Enum.uniq(
           List.wrap(ObserveConfig.tracer(instance)) ++
             List.wrap(Application.get_env(:ash, :tracer))
         ) do
      [] -> nil
      [tracer] -> tracer
      tracers -> tracers
    end
  end
end
