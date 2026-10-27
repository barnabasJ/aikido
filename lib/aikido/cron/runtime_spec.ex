defmodule Aikido.Cron.RuntimeSpec do
  @moduledoc false

  alias Aikido.Signal

  @default_timezone "Etc/UTC"

  @enforce_keys [:kind, :cron_expression, :timezone]
  # Caller scope belongs only to this live job. Durable definitions retain the
  # original message separately and rebuild this context empty on activation.
  defstruct [
    :kind,
    :cron_expression,
    :timezone,
    :message,
    :signal_type,
    data: %{},
    scope: %{},
    tracer_context: %{}
  ]

  @type kind :: :dynamic | :schedule

  @type t ::
          %__MODULE__{
            kind: kind(),
            cron_expression: String.t(),
            timezone: String.t(),
            message: term() | nil,
            signal_type: String.t() | nil,
            scope: map(),
            tracer_context: map()
          }

  @spec dynamic(String.t(), term(), String.t() | nil, Signal.t() | nil) :: t()
  def dynamic(cron_expression, message, timezone \\ nil, origin \\ nil)
      when is_binary(cron_expression) do
    %__MODULE__{
      kind: :dynamic,
      cron_expression: cron_expression,
      timezone: normalize_timezone(timezone),
      message: message,
      scope: if(origin, do: Signal.ctx(origin), else: %{}),
      tracer_context: if(origin, do: Signal.tracer_context(origin), else: %{})
    }
  end

  @spec schedule(String.t(), String.t(), String.t() | nil) :: t()
  def schedule(cron_expression, signal_type, timezone \\ nil, data \\ %{})
      when is_binary(cron_expression) and is_binary(signal_type) do
    %__MODULE__{
      kind: :schedule,
      cron_expression: cron_expression,
      timezone: normalize_timezone(timezone),
      signal_type: signal_type,
      data: data
    }
  end

  @spec build_signal(t(), String.t(), term()) :: Aikido.Signal.t()
  def build_signal(
        %__MODULE__{kind: :dynamic, message: %Signal{} = signal} = spec,
        _agent_id,
        _logical_id
      ) do
    signal
    |> Aikido.Directive.materialize_signal()
    |> inherit_job_scope(spec)
  end

  def build_signal(%__MODULE__{kind: :dynamic, message: message} = spec, agent_id, logical_id) do
    %{job_id: logical_id, message: message}
    |> Aikido.Cron.Signals.Tick.new!(source: "/agent/#{agent_id}")
    |> inherit_job_scope(spec)
  end

  def build_signal(
        %__MODULE__{kind: :schedule, signal_type: signal_type, data: data},
        agent_id,
        _logical_id
      ) do
    Signal.new!(signal_type, data, source: "/agent/#{agent_id}/schedule")
  end

  defp inherit_job_scope(signal, spec) do
    Signal.inherit(signal, %Signal{
      type: signal.type,
      scope: spec.scope,
      tracer_context: spec.tracer_context
    })
  end

  defp normalize_timezone(nil), do: @default_timezone
  defp normalize_timezone(""), do: @default_timezone
  defp normalize_timezone(timezone), do: timezone
end
