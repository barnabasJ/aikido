defmodule Aikido.AiReact.Errors.ProviderRequestFailed do
  @moduledoc "Public provider failure details without request bodies, headers or raw provider messages."
  use Splode.Error, fields: [:cause_type, :status, :timeout_phase, :timeout_ms], class: :invalid

  @doc "Convert native ReqLLM failures at the model-call boundary; retain application error contracts."
  def from_reason(%{__struct__: module} = error) when is_atom(module) and is_exception(error) do
    case Module.split(module) do
      ["ReqLLM", "Error" | _] ->
        error = first_provider_error(error)

        exception(
          cause_type: error.__struct__,
          status: public_status(Map.get(error, :status)),
          timeout_phase: public_timeout_phase(Map.get(error, :kind)),
          timeout_ms: public_timeout(Map.get(error, :timeout))
        )

      _ ->
        error
    end
  end

  def from_reason(error), do: error

  def message(error) do
    [failure_description(error), recovery(error)] |> Enum.join(" ")
  end

  @doc "Recovery instructions based only on the public HTTP or timeout classification."
  def recovery(%{timeout_ms: timeout}) when is_integer(timeout) do
    "Check request progress and the remaining run deadline. Shorten the request or increase its attempt timeout within that deadline; do not retry with an expired budget."
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
    %{
      message: Aikido.AiReact.Errors.ProviderRequestFailed.message(error),
      short_message: "Model provider request failed",
      code: Aikido.AiReact.Errors.ProviderRequestFailed.code(error),
      fields: [],
      vars: %{
        status: error.status,
        timeout_phase: error.timeout_phase,
        timeout_ms: error.timeout_ms,
        recovery: Aikido.AiReact.Errors.ProviderRequestFailed.recovery(error)
      }
    }
  end
end
