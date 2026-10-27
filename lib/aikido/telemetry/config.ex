defmodule Aikido.Telemetry.Config do
  @moduledoc """
  Resolves observability configuration with per-instance support.

  Resolution order (highest priority first):

  1. `Aikido.Debug` runtime override (persistent_term, per-instance)
  2. Per-instance app config (`config :my_app, MyApp.Aikido, telemetry: [...]`)
  3. Global app config (`config :aikido, :telemetry` / `config :aikido, :observability`)
  4. Hardcoded default

  When `instance` is `nil`, steps 1-2 are skipped.
  """

  alias Aikido.Config.Defaults

  @type instance :: atom() | nil

  @telemetry_log_levels [:trace, :debug, :info, :warning, :error]

  # --- Telemetry settings ---

  @doc "Returns the telemetry log level for the given instance."
  @spec telemetry_log_level(instance()) :: :trace | :debug | :info | :warning | :error
  def telemetry_log_level(instance \\ nil)

  def telemetry_log_level(nil) do
    global_telemetry(:log_level, Defaults.telemetry_log_level())
    |> normalize_telemetry_log_level()
  end

  def telemetry_log_level(instance) do
    with nil <- Aikido.Debug.override(instance, :telemetry_log_level),
         nil <- instance_telemetry(instance, :log_level) do
      global_telemetry(:log_level, Defaults.telemetry_log_level())
    end
    |> normalize_telemetry_log_level()
  end

  @doc "Returns the slow signal threshold in milliseconds."
  @spec slow_signal_threshold_ms(instance()) :: non_neg_integer()
  def slow_signal_threshold_ms(instance \\ nil)

  def slow_signal_threshold_ms(nil),
    do:
      global_telemetry(:slow_signal_threshold_ms, Defaults.slow_signal_threshold_ms())
      |> normalize_non_neg_integer(Defaults.slow_signal_threshold_ms())

  def slow_signal_threshold_ms(instance) do
    with nil <- Aikido.Debug.override(instance, :slow_signal_threshold_ms),
         nil <- instance_telemetry(instance, :slow_signal_threshold_ms) do
      global_telemetry(:slow_signal_threshold_ms, Defaults.slow_signal_threshold_ms())
    end
    |> normalize_non_neg_integer(Defaults.slow_signal_threshold_ms())
  end

  @doc "Returns the slow directive threshold in milliseconds."
  @spec slow_directive_threshold_ms(instance()) :: non_neg_integer()
  def slow_directive_threshold_ms(instance \\ nil)

  def slow_directive_threshold_ms(nil),
    do:
      global_telemetry(:slow_directive_threshold_ms, Defaults.slow_directive_threshold_ms())
      |> normalize_non_neg_integer(Defaults.slow_directive_threshold_ms())

  def slow_directive_threshold_ms(instance) do
    with nil <- Aikido.Debug.override(instance, :slow_directive_threshold_ms),
         nil <- instance_telemetry(instance, :slow_directive_threshold_ms) do
      global_telemetry(:slow_directive_threshold_ms, Defaults.slow_directive_threshold_ms())
    end
    |> normalize_non_neg_integer(Defaults.slow_directive_threshold_ms())
  end

  @doc "Returns the list of signal types considered interesting."
  @spec interesting_signal_types(instance()) :: [String.t()]
  def interesting_signal_types(instance \\ nil)

  def interesting_signal_types(nil),
    do:
      global_telemetry(:interesting_signal_types, Defaults.interesting_signal_types())
      |> normalize_interesting_signal_types()

  def interesting_signal_types(instance) do
    with nil <- Aikido.Debug.override(instance, :interesting_signal_types),
         nil <- instance_telemetry(instance, :interesting_signal_types) do
      global_telemetry(:interesting_signal_types, Defaults.interesting_signal_types())
    end
    |> normalize_interesting_signal_types()
  end

  @doc "Returns true if trace-level logging is enabled."
  @spec trace_enabled?(instance()) :: boolean()
  def trace_enabled?(instance \\ nil) do
    telemetry_log_level(instance) == :trace
  end

  @doc "Returns true if debug-level logging is enabled."
  @spec debug_enabled?(instance()) :: boolean()
  def debug_enabled?(instance \\ nil) do
    telemetry_log_level(instance) in [:trace, :debug]
  end

  @doc "Returns true if the signal type is considered interesting."
  @spec interesting_signal_type?(instance(), String.t()) :: boolean()
  def interesting_signal_type?(instance \\ nil, signal_type) do
    signal_type in interesting_signal_types(instance)
  end

  # --- Observe settings ---

  @doc "Returns the tracer module for the given instance."
  @spec tracer(instance()) :: module() | [module()] | nil
  def tracer(instance \\ nil)

  def tracer(nil) do
    global_observability(:tracer, Defaults.tracer())
    |> normalize_tracer()
  end

  def tracer(instance) do
    with nil <- Aikido.Debug.override(instance, :tracer),
         nil <- instance_observability(instance, :tracer) do
      global_observability(:tracer, Defaults.tracer())
    end
    |> normalize_tracer()
  end

  # --- Debug buffer settings ---

  @doc "Returns the maximum number of debug events to store."
  @spec debug_max_events(instance()) :: non_neg_integer()
  def debug_max_events(instance \\ nil)

  def debug_max_events(nil) do
    global_telemetry(:debug_max_events, Defaults.debug_max_events())
    |> normalize_non_neg_integer(Defaults.debug_max_events())
  end

  def debug_max_events(instance) do
    with nil <- Aikido.Debug.override(instance, :debug_max_events),
         nil <- instance_telemetry(instance, :debug_max_events) do
      global_telemetry(:debug_max_events, Defaults.debug_max_events())
    end
    |> normalize_non_neg_integer(Defaults.debug_max_events())
  end

  # --- Private helpers ---

  defp instance_telemetry(instance, key), do: instance_option(instance, :telemetry, key)
  defp instance_observability(instance, key), do: instance_option(instance, :observability, key)

  defp instance_option(instance, section, key) when is_atom(instance) do
    if function_exported?(instance, :spark_is, 0) and
         Spark.Dsl.is?(instance, Aikido.Instance.Host) do
      instance
      |> Aikido.config()
      |> Keyword.get(section, [])
      |> Keyword.get(key)
    end
  end

  defp global_telemetry(key, default) do
    :aikido |> Application.get_env(:telemetry, []) |> Keyword.get(key, default)
  end

  defp global_observability(key, default) do
    :aikido |> Application.get_env(:observability, []) |> Keyword.get(key, default)
  end

  defp normalize_telemetry_log_level(level) when level in @telemetry_log_levels, do: level
  defp normalize_telemetry_log_level(_), do: Defaults.telemetry_log_level()

  defp normalize_interesting_signal_types(types) when is_list(types) do
    if Enum.all?(types, &is_binary/1), do: types, else: Defaults.interesting_signal_types()
  end

  defp normalize_interesting_signal_types(_), do: Defaults.interesting_signal_types()

  defp normalize_non_neg_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_integer(_, default), do: default

  defp normalize_tracer(module) when is_atom(module) and not is_nil(module) do
    if Spark.implements_behaviour?(module, Ash.Tracer), do: module
  end

  defp normalize_tracer(modules) when is_list(modules) do
    Enum.filter(modules, &Spark.implements_behaviour?(&1, Ash.Tracer))
  end

  defp normalize_tracer(_), do: nil
end
