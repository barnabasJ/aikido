defmodule AgentExamples.Settings do
  @moduledoc "Persistent browser provider settings; secrets are decrypted only at the request boundary."
  use Ash.Domain, otp_app: :agent_examples
  alias AgentExamples.Settings.{Preference, Credential}

  resources do
    resource Preference
    resource Credential
  end

  def provider_settings(owner) do
    case Ash.get(Preference, owner, not_found_error?: false) do
      {:ok, nil} -> AgentExamples.AI.Providers.defaults()
      {:ok, preference} -> Map.take(preference, [:mode, :provider, :model, :key_configured?])
      {:error, error} -> raise error
    end
  end

  def provider_key(owner, provider) do
    with {:ok, credential} <-
           Ash.get(
             Credential,
             %{owner: owner, provider: AgentExamples.AI.Providers.credential_provider(provider)},
             not_found_error?: false
           ),
         true <- not is_nil(credential) || {:error, :not_configured},
         {:ok, credential} <- Ash.load(credential, :api_key) do
      {:ok, credential.api_key}
    end
  end

  def save_provider(owner, settings, key) do
    Ash.transact([Preference, Credential], fn ->
      with :ok <- save_credential(owner, settings, key),
           {:ok, _} <- Ash.create(Preference, Map.put(settings, :owner, owner), action: :save) do
        settings
      end
    end)
  end

  defp save_credential(owner, %{mode: "live", provider: provider}, key) do
    case Ash.create(
           Credential,
           %{
             owner: owner,
             provider: AgentExamples.AI.Providers.credential_provider(provider),
             api_key: key
           },
           action: :save
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp save_credential(_, _, _), do: :ok
end
