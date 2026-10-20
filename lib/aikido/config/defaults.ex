defmodule Aikido.Config.Defaults do
  @moduledoc """
  Centralized default values for runtime behavior and observability.

  Keeping defaults in one module avoids drift across API wrappers, runtime
  modules, and configuration resolution.
  """

  @type telemetry_log_level :: :trace | :debug | :info | :warning | :error

  @aikido_shutdown_timeout_ms 10_000

  @agent_server_call_timeout_ms 5_000
  @agent_server_await_timeout_ms 10_000

  @telemetry_log_level :info
  @slow_signal_threshold_ms 10
  @slow_directive_threshold_ms 5
  @interesting_signal_types []
  @tracer nil
  @debug_max_events 500

  @doc "Default shutdown timeout for the top-level Aikido supervisor."
  @spec aikido_shutdown_timeout_ms() :: pos_integer()
  def aikido_shutdown_timeout_ms, do: @aikido_shutdown_timeout_ms

  @doc "Default timeout for synchronous AgentServer calls."
  @spec agent_server_call_timeout_ms() :: pos_integer()
  def agent_server_call_timeout_ms, do: @agent_server_call_timeout_ms

  @doc "Default timeout for AgentServer waiting primitives (call/4, await_child/3, await_ready/2)."
  @spec agent_server_await_timeout_ms() :: pos_integer()
  def agent_server_await_timeout_ms, do: @agent_server_await_timeout_ms

  @doc "Default telemetry log level."
  @spec telemetry_log_level() :: telemetry_log_level()
  def telemetry_log_level, do: @telemetry_log_level

  @doc "Default slow-signal threshold in milliseconds."
  @spec slow_signal_threshold_ms() :: non_neg_integer()
  def slow_signal_threshold_ms, do: @slow_signal_threshold_ms

  @doc "Default slow-directive threshold in milliseconds."
  @spec slow_directive_threshold_ms() :: non_neg_integer()
  def slow_directive_threshold_ms, do: @slow_directive_threshold_ms

  @doc "Default list of interesting signal types."
  @spec interesting_signal_types() :: [String.t()]
  def interesting_signal_types, do: @interesting_signal_types

  @doc "Default tracer module."
  @spec tracer() :: nil
  def tracer, do: @tracer

  @doc "Default max debug-event buffer size."
  @spec debug_max_events() :: non_neg_integer()
  def debug_max_events, do: @debug_max_events
end
