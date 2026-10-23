defmodule Aikido.Telemetry do
  @moduledoc """
  Production-ready telemetry for Aikido Agent operations.

  Provides structured, scannable logging with intelligent filtering to reduce noise
  while preserving actionable debugging information.

  ## Log Levels

  The telemetry system uses three effective log levels:

  - **INFO** - Developer narrative for user-facing interactions (request start/stop)
  - **DEBUG** - Interesting events only (slow operations, signals with directives, errors)
  - **TRACE** - Fine-grained internal churn (every signal/directive) - opt-in via config

  ## Configuration

  Configure via application environment:

      config :aikido, :telemetry,
        log_level: :debug,                    # :trace | :debug | :info
        slow_signal_threshold_ms: 10,         # Log signals slower than this
        slow_directive_threshold_ms: 5,       # Log directives slower than this
        interesting_signal_types: [           # Always log these signal types
          "aikido.agent.user_request",
          "aikido.tool.result",
          "aikido.llm.done"
        ]

  ## "Interestingness" Filtering

  At DEBUG level, signals are only logged if they are "interesting":
  - Duration exceeds `slow_signal_threshold_ms`
  - Produced one or more directives
  - Signal type is in `interesting_signal_types`
  - An error occurred

  This reduces log spam from high-frequency internal signals while preserving
  visibility into operations that matter.

  ## Structured Output

  All log entries include structured metadata for filtering and correlation:
  - Signal IDs and types identify the work; Ash tracers supply span ancestry.
  - `agent_id`, `agent_module` - Agent identification
  - `signal_type`, `directive_count`, `directive_types` - What happened
  - `duration` - Formatted timing (e.g., "12.3ms")

  ## Events

  ### AgentServer Events
  - `[:aikido, :agent_server, :signal, :start]` - Signal processing started
  - `[:aikido, :agent_server, :signal, :stop]` - Signal processing completed
  - `[:aikido, :agent_server, :signal, :exception]` - Signal processing failed
  - `[:aikido, :agent_server, :directive, :start]` - Directive execution started
  - `[:aikido, :agent_server, :directive, :stop]` - Directive execution completed
  - `[:aikido, :agent_server, :directive, :exception]` - Directive execution failed
  - `[:aikido, :agent_server, :cron, :register]` - Dynamic cron registered
  - `[:aikido, :agent_server, :cron, :cancel]` - Dynamic cron cancelled
  - `[:aikido, :agent_server, :cron, :restart_scheduled]` - Dynamic cron restart scheduled
  - `[:aikido, :agent_server, :cron, :restart_succeeded]` - Dynamic cron restart completed

  """

  require Logger

  alias Aikido.Telemetry.Config
  alias Aikido.Telemetry.Formatter

  @typedoc """
  Supported telemetry event names.
  """
  @type event_name :: [atom(), ...]

  @typedoc """
  Telemetry measurements map.
  """
  @type measurements :: %{
          optional(:system_time) => integer(),
          optional(:duration) => integer(),
          atom() => term()
        }

  @typedoc """
  Telemetry metadata map.
  """
  @type metadata :: %{
          optional(:agent_id) => String.t(),
          optional(:agent_module) => module(),
          optional(:action) => term(),
          optional(:directive_count) => non_neg_integer(),
          optional(:error) => term(),
          atom() => term()
        }

  @handler_id "aikido-agent-metrics"

  @doc """
  Attaches telemetry handlers. Idempotent — safe to call multiple times.
  Called from application startup.
  """
  @spec setup() :: :ok
  def setup do
    _ = :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, events(), &__MODULE__.handle_event/4, nil)
    :ok
  end

  @doc """
  Returns telemetry metric definitions with automatic per-instance scoping.

  Wire these into your reporter in your application:

      TelemetryMetricsPrometheus.init(Aikido.Telemetry.metrics())
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    tag_values = &instance_tag_values/1

    [
      Telemetry.Metrics.counter("aikido.agent_server.signal.stop.count",
        event_name: [:aikido, :agent_server, :signal, :stop],
        measurement: fn _ -> 1 end,
        tags: [:aikido_instance, :signal_type],
        tag_values: tag_values,
        description: "Total signals processed"
      ),
      Telemetry.Metrics.summary("aikido.agent_server.signal.stop.duration",
        tags: [:aikido_instance, :signal_type],
        tag_values: tag_values,
        unit: {:native, :millisecond},
        description: "Signal processing duration summary"
      ),
      Telemetry.Metrics.counter("aikido.agent_server.directive.stop.count",
        event_name: [:aikido, :agent_server, :directive, :stop],
        measurement: fn _ -> 1 end,
        tags: [:aikido_instance, :directive_type],
        tag_values: tag_values,
        description: "Total directives executed"
      )
    ]
  end

  defp instance_tag_values(meta) do
    meta
    |> Map.new()
    |> Map.put_new(:aikido_instance, :global)
  end

  defp events do
    [
      [:aikido, :agent_server, :signal, :start],
      [:aikido, :agent_server, :signal, :stop],
      [:aikido, :agent_server, :signal, :exception],
      [:aikido, :agent_server, :directive, :start],
      [:aikido, :agent_server, :directive, :stop],
      [:aikido, :agent_server, :directive, :exception],
      [:aikido, :agent_server, :cron, :register],
      [:aikido, :agent_server, :cron, :cancel],
      [:aikido, :agent_server, :cron, :restart_scheduled],
      [:aikido, :agent_server, :cron, :restart_succeeded]
    ]
  end

  @doc """
  Handles telemetry events for AgentServer signals, directives and schedules.

  Uses intelligent filtering to reduce noise while preserving actionable information.
  Events are logged based on "interestingness" criteria configured via `Aikido.Telemetry.Config`.
  """
  @spec handle_event(event_name(), measurements(), metadata(), config :: term()) :: :ok

  # ---------------------------------------------------------------------------
  # AgentServer Signal Events - The main source of log noise
  # ---------------------------------------------------------------------------

  def handle_event([:aikido, :agent_server, :signal, :start], _measurements, _metadata, _config) do
    :ok
  end

  def handle_event([:aikido, :agent_server, :signal, :stop], measurements, metadata, _config) do
    instance = metadata[:aikido_instance]
    duration = Map.get(measurements, :duration, 0)
    duration_ms = Formatter.to_ms(duration)
    directive_count = metadata[:directive_count] || 0
    signal_type = metadata[:signal_type]

    cond do
      # At trace level, log everything
      Config.trace_enabled?(instance) ->
        log_signal_stop(metadata, duration, directive_count)

      # At debug level, only log "interesting" signals
      Config.debug_enabled?(instance) and
          interesting_signal?(instance, signal_type, duration_ms, directive_count, metadata) ->
        log_signal_stop(metadata, duration, directive_count)

      # Otherwise, stay silent
      true ->
        :ok
    end

    :ok
  end

  def handle_event(
        [:aikido, :agent_server, :signal, :exception],
        measurements,
        metadata,
        _config
      ) do
    duration = Map.get(measurements, :duration, 0)

    Logger.warning(
      "[signal.error] type=#{Formatter.format_signal_type(metadata[:signal_type])} " <>
        "error=#{Formatter.safe_inspect(metadata[:error], 200)} " <>
        "duration=#{Formatter.format_duration(duration)}",
      agent_id: metadata[:agent_id],
      stacktrace: metadata[:stacktrace]
    )
  end

  # ---------------------------------------------------------------------------
  # AgentServer Directive Events
  # ---------------------------------------------------------------------------

  def handle_event(
        [:aikido, :agent_server, :directive, :start],
        _measurements,
        _metadata,
        _config
      ) do
    :ok
  end

  def handle_event([:aikido, :agent_server, :directive, :stop], measurements, metadata, _config) do
    instance = metadata[:aikido_instance]
    duration = Map.get(measurements, :duration, 0)
    duration_ms = Formatter.to_ms(duration)
    directive_type = metadata[:directive_type]

    cond do
      # At trace level, log everything
      Config.trace_enabled?(instance) ->
        log_directive_stop(metadata, duration)

      # At debug level, only log slow or interesting directives
      Config.debug_enabled?(instance) and
          interesting_directive?(instance, directive_type, duration_ms, metadata) ->
        log_directive_stop(metadata, duration)

      # Otherwise, stay silent
      true ->
        :ok
    end

    :ok
  end

  def handle_event(
        [:aikido, :agent_server, :directive, :exception],
        measurements,
        metadata,
        _config
      ) do
    duration = Map.get(measurements, :duration, 0)

    Logger.warning(
      "[directive.error] type=#{metadata[:directive_type]} " <>
        "error=#{Formatter.safe_inspect(metadata[:error], 200)} " <>
        "duration=#{Formatter.format_duration(duration)}",
      agent_id: metadata[:agent_id],
      stacktrace: metadata[:stacktrace]
    )
  end

  def handle_event([:aikido, :agent_server, :cron, :register], _measurements, metadata, _config) do
    Logger.debug(
      "[cron.register] job_id=#{inspect(metadata[:job_id])} cron=#{inspect(metadata[:cron_expression])}",
      agent_id: metadata[:agent_id]
    )
  end

  def handle_event([:aikido, :agent_server, :cron, :cancel], _measurements, metadata, _config) do
    Logger.debug(
      "[cron.cancel] job_id=#{inspect(metadata[:job_id])}",
      agent_id: metadata[:agent_id]
    )
  end

  def handle_event(
        [:aikido, :agent_server, :cron, :restart_scheduled],
        _measurements,
        metadata,
        _config
      ) do
    Logger.debug(
      "[cron.restart_scheduled] job_id=#{inspect(metadata[:job_id])} reason=#{Formatter.safe_inspect(metadata[:reason], 120)} delay_ms=#{inspect(metadata[:delay_ms])}",
      agent_id: metadata[:agent_id]
    )
  end

  def handle_event(
        [:aikido, :agent_server, :cron, :restart_succeeded],
        _measurements,
        metadata,
        _config
      ) do
    Logger.debug(
      "[cron.restart_succeeded] job_id=#{inspect(metadata[:job_id])} cron=#{inspect(metadata[:cron_expression])}",
      agent_id: metadata[:agent_id]
    )
  end

  # ---------------------------------------------------------------------------
  # Private: Logging Helpers
  # ---------------------------------------------------------------------------

  defp log_signal_stop(metadata, duration, directive_count) do
    Logger.debug(
      fn ->
        directive_types =
          metadata[:directive_types]
          |> Formatter.format_directive_types()

        directive_summary =
          if directive_types == "" do
            ""
          else
            "#{directive_types} "
          end

        "[signal] type=#{Formatter.format_signal_type(metadata[:signal_type])} " <>
          "directives=#{directive_count} " <>
          directive_summary <>
          "duration=#{Formatter.format_duration(duration)}" <>
          if(is_nil(metadata[:error]),
            do: "",
            else: " error=#{Formatter.safe_inspect(metadata.error)}"
          )
      end,
      agent_id: metadata[:agent_id],
      signal_id: metadata[:signal_id]
    )
  end

  defp log_directive_stop(metadata, duration) do
    Logger.debug(
      fn ->
        "[directive] type=#{metadata[:directive_type]} " <>
          "result=#{metadata[:result]} " <>
          "duration=#{Formatter.format_duration(duration)}"
      end,
      agent_id: metadata[:agent_id],
      signal_id: metadata[:signal_id]
    )
  end

  # ---------------------------------------------------------------------------
  # Private: Interestingness Checks
  # ---------------------------------------------------------------------------

  defp interesting_signal?(instance, signal_type, duration_ms, directive_count, metadata) do
    is_slow = duration_ms > Config.slow_signal_threshold_ms(instance)
    has_directives = directive_count > 0
    is_interesting_type = Config.interesting_signal_type?(instance, to_string(signal_type))
    has_error = metadata[:error] != nil

    is_slow or has_directives or is_interesting_type or has_error
  end

  defp interesting_directive?(instance, directive_type, duration_ms, metadata) do
    is_slow = duration_ms > Config.slow_directive_threshold_ms(instance)
    has_error = metadata[:error] != nil
    interesting_types = ["Tool", "LLM", "Await", "Spawn"]
    is_interesting_type = directive_type in interesting_types

    is_slow or has_error or is_interesting_type
  end
end
