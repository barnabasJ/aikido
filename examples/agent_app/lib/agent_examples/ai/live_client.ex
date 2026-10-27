defmodule AgentExamples.AI.LiveClient do
  @moduledoc "Loads a browser's AshCloak-encrypted key at the I/O boundary and calls native ReqLLM. Agent state contains only the owner reference."
  @behaviour Aikido.AiReact.Client
  alias Aikido.AiReact.Errors.ProviderRequestFailed

  @impl true
  def generate_text(model, messages, opts), do: request(:generate_text, model, messages, opts)
  @impl true
  def stream_text(model, messages, opts), do: request(:stream_text, model, messages, opts)

  defp request(operation, model, messages, opts) do
    with {:ok, key} <-
           AgentExamples.Settings.provider_key(model.credential_owner, model.provider),
         {:ok, response} <-
           apply(ReqLLM.Generation, operation, [
             Map.take(model, [:provider, :id]),
             messages,
             Keyword.put(opts, :api_key, key)
           ]) do
      {:ok, response}
    else
      {:error, :not_configured} ->
        {:error,
         "No saved API key is available for this agent's provider. Save the provider credential in AI settings and restart the example before retrying."}

      {:error, error} ->
        {:error, provider_failure(error)}
    end
  rescue
    error -> {:error, provider_failure(error)}
  end

  defp provider_failure(error) do
    case ProviderRequestFailed.from_reason(error) do
      %ProviderRequestFailed{} = public -> public
      %{__struct__: module} -> ProviderRequestFailed.exception(cause_type: module)
      _ -> ProviderRequestFailed.exception(cause_type: :unexpected_provider_result)
    end
  end
end
