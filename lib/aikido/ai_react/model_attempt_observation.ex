defmodule Aikido.AiReact.ModelAttemptObservation do
  @moduledoc "Builds safe model attempt facts at the I/O boundary, without retaining provider payloads."

  alias Aikido.AiReact.{AttemptTiming, Errors.ProviderRequestFailed}

  @doc "Project only the failure class, HTTP status and timeout phase."
  def failure(%Aikido.AiReact.Errors.EffectReceiptLost{} = error), do: failure_fields(error)

  def failure(reason) do
    case ProviderRequestFailed.from_reason(reason) do
      %ProviderRequestFailed{} = error ->
        failure_fields(error)

      %{__struct__: module} ->
        %{cause_type: module}

      _ ->
        %{}
    end
  end

  defp failure_fields(error) do
    Map.take(error, [:cause_type, :status, :timeout_phase, :transport_type, :transport_reason])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc "Create a transient observer that emits a typed, scoped signal and safe telemetry."
  def observer(directive, owner, source, scope) do
    timing = AttemptTiming.resolve(get_in(scope, [:context, :aikido_attempt_timing]))

    fn attempt, phase, facts ->
      time = AttemptTiming.system_ms(timing)

      observation =
        %{
          request_id: directive.request_id,
          iteration: directive.iteration,
          attempt: attempt,
          mode: directive.mode,
          handoff_id: directive.handoff_id,
          deadline_at: directive.deadline_at,
          phase: phase
        }
        |> Map.merge(facts)
        |> stamp(phase, time)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      signal =
        Aikido.AiReact.Signals.ModelAttempt.new!(%{observation: observation}, source: source)
        |> Aikido.Signal.put_ctx(scope)

      Aikido.AgentServer.cast(owner, signal)
      measurements = %{system_time: System.convert_time_unit(time, :millisecond, :native)}

      measurements =
        if duration = facts[:duration_ms],
          do:
            Map.put(
              measurements,
              :duration,
              System.convert_time_unit(duration, :millisecond, :native)
            ),
          else: measurements

      :telemetry.execute([:aikido, :ai, :model_attempt, phase], measurements, observation)
    end
  end

  defp stamp(facts, :started, time), do: Map.put(facts, :started_at, time)
  defp stamp(facts, :ended, time), do: Map.put(facts, :ended_at, time)
  defp stamp(facts, :cleanup, time), do: Map.put(facts, :cleanup_at, time)
  defp stamp(facts, :terminal, time), do: Map.put(facts, :delivered_at, time)

  defp stamp(facts, phase, time) when phase in [:backoff, :provider_backoff],
    do: Map.put(facts, :retry_at, time + facts.delay_ms)

  defp stamp(facts, _phase, _time), do: facts
end
