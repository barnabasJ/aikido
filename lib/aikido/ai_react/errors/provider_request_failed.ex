defmodule Aikido.AiReact.Errors.ProviderRequestFailed do
  @moduledoc "Public provider failure details without request bodies, headers or raw provider messages."
  use Splode.Error,
    fields: [
      :cause_type,
      :status,
      :timeout_phase,
      :timeout_ms,
      :parameter,
      :transport_type,
      :transport_reason
    ],
    class: :invalid

  @doc "Convert native ReqLLM failures at the model-call boundary; retain application error contracts."
  def from_reason(%Aikido.AiReact.Errors.ModelTimeout{} = error) do
    exception(cause_type: error.__struct__, timeout_phase: error.kind, timeout_ms: error.timeout)
  end

  def from_reason(%{__struct__: module} = error)
      when module in [Req.TransportError, Finch.TransportError, Mint.TransportError] do
    exception([cause_type: module] ++ transport_fields(error))
  end

  def from_reason(%{__struct__: module} = error) when is_atom(module) and is_exception(error) do
    case Module.split(module) do
      ["ReqLLM", "Error" | _] ->
        error = first_provider_error(error)

        exception(
          [
            cause_type: error.__struct__,
            status: public_status(Map.get(error, :status)),
            timeout_phase: public_timeout_phase(Map.get(error, :kind)),
            timeout_ms: public_timeout(Map.get(error, :timeout)),
            parameter: public_parameter(error)
          ] ++ transport_fields(error)
        )

      _ ->
        error
    end
  end

  def from_reason(error), do: error

  def message(error) do
    [
      failure_description(error),
      transport_description(error),
      parameter_description(error),
      recovery(error)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc "Recovery instructions based only on the public HTTP or timeout classification."
  def recovery(%{timeout_ms: timeout}) when is_integer(timeout) do
    "Check request progress and the remaining run deadline. Shorten the request or increase its attempt timeout within that deadline; do not retry with an expired budget."
  end

  def recovery(%{transport_reason: :timeout}) do
    "The transport reported a timeout without identifying its phase. Check progress and remaining run budget before retrying."
  end

  def recovery(%{status: 429}) do
    "HTTP 429 can reflect a rate or quota limit. Check provider quota, concurrent requests and that the credential matches the intended plan. Retry with backoff only if budget remains; do not repeat the request unchanged while the limit persists."
  end

  def recovery(%{status: status}) when status in [401, 403] do
    "Check the provider endpoint, API credential and model access. Correct the configuration before retrying; do not repeat the same request unchanged."
  end

  def recovery(%{status: status}) when status in [400, 404, 422] do
    "Check the provider endpoint, model ID, request options and tool schemas. Correct the configuration before retrying."
  end

  def recovery(%{status: status}) when is_integer(status) and status >= 500 do
    "The provider returned a server error. Retry with backoff only within the remaining run budget, or report partial findings and request a new run."
  end

  def recovery(_error) do
    "Check provider connectivity, model configuration and response compatibility. Inspect runtime diagnostics without sharing credentials; correct the cause before retrying within the remaining run budget."
  end

  @doc "The stable tool error code for this failure."
  def code(%{timeout_ms: timeout}) when is_integer(timeout), do: "provider_timeout"
  def code(%{transport_reason: :timeout}), do: "provider_timeout"
  def code(_error), do: "provider_request_failed"

  defp failure_description(%{timeout_ms: timeout, timeout_phase: phase}) when is_integer(timeout),
    do: "The model provider request timed out after #{timeout}ms (#{phase || :unspecified})."

  defp failure_description(%{status: status, cause_type: cause}) when status in 200..299,
    do:
      "The provider returned HTTP #{status}, but no usable model response was decoded (#{inspect(cause)})."

  defp failure_description(%{status: status, cause_type: cause}) when is_integer(status),
    do: "The model provider request failed (HTTP #{status}; #{inspect(cause)})."

  defp failure_description(%{cause_type: cause}),
    do: "The model provider request did not produce a usable response (#{inspect(cause)})."

  defp first_provider_error(%{errors: [%{__struct__: _} = first | _]}),
    do: first_provider_error(first)

  defp first_provider_error(error), do: error

  defp transport_fields(error) do
    cause = Map.get(error, :cause) || error

    with %{__struct__: module} <- cause,
         {:transport, reason, _retryable} <- ReqLLM.Streaming.Failure.classify(cause),
         {:ok, reason} <-
           Ash.Type.cast_input(Aikido.AiReact.Types.ProviderTransportReason, reason) do
      [transport_type: module, transport_reason: reason]
    else
      _ -> []
    end
  end

  defp public_parameter(%ReqLLM.Error.Invalid.Parameter{parameter: name})
       when is_binary(name) or (is_atom(name) and name not in [nil, true, false]) do
    case Ash.Type.cast_input(Aikido.AiReact.Types.ProviderParameterName, name) do
      {:ok, name} -> name
      _ -> nil
    end
  end

  defp public_parameter(_error), do: nil

  defp parameter_description(%{parameter: name}) when is_binary(name), do: "Parameter: #{name}."
  defp parameter_description(_error), do: nil

  defp transport_description(%{transport_type: module, transport_reason: reason})
       when not is_nil(reason),
       do: "Transport: #{inspect(module)} (#{reason})."

  defp transport_description(_error), do: nil

  defp public_status(status) when is_integer(status) and status in 100..599, do: status
  defp public_status(_status), do: nil

  defp public_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp public_timeout(_timeout), do: nil

  defp public_timeout_phase(phase) when phase in [:connect, :receive, :total, :stream_idle],
    do: phase

  defp public_timeout_phase(_phase), do: nil
end

defimpl AshAi.ToToolError, for: Aikido.AiReact.Errors.ProviderRequestFailed do
  def to_tool_error(error), do: Aikido.AiReact.Errors.ProviderRequestFailed.message(error)
end

defimpl AshLua.Error, for: Aikido.AiReact.Errors.ProviderRequestFailed do
  def to_error(error) do
    vars = %{
      status: error.status,
      timeout_phase: error.timeout_phase,
      timeout_ms: error.timeout_ms,
      transport_type: error.transport_type,
      transport_reason: error.transport_reason,
      recovery: Aikido.AiReact.Errors.ProviderRequestFailed.recovery(error)
    }

    %{
      message: Aikido.AiReact.Errors.ProviderRequestFailed.message(error),
      short_message: "Model provider request failed",
      code: Aikido.AiReact.Errors.ProviderRequestFailed.code(error),
      fields: [],
      vars:
        if(is_nil(error.parameter), do: vars, else: Map.put(vars, :parameter, error.parameter))
    }
  end
end
