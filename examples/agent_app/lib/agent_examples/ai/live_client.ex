defmodule AgentExamples.AI.LiveClient do
  @moduledoc "Loads a browser's AshCloak-encrypted key at the I/O boundary and calls native ReqLLM. Agent state contains only the owner reference."
  @behaviour Aikido.AiReact.Client

  @impl true
  def generate_text(model, messages, opts), do: request(:generate_text, model, messages, opts)
  @impl true
  def stream_text(model, messages, opts), do: request(:stream_text, model, messages, opts)

  defp request(operation, model, messages, opts) do
    with {:ok, key} <-
           AgentExamples.Playground.provider_key(model.credential_owner, model.provider) do
      native_model = Map.take(model, [:provider, :id])

      try do
        case apply(ReqLLM.Generation, operation, [
               native_model,
               messages,
               Keyword.put(opts, :api_key, key)
             ]) do
          {:error, error} -> {:error, redact_error(error, key)}
          result -> result
        end
      rescue
        error -> {:error, redact_error(error, key)}
      end
    end
  end

  defp redact_error(error, key) do
    message = if is_exception(error), do: Exception.message(error), else: inspect(error)
    String.replace(message, key, "[REDACTED]")
  end
end
