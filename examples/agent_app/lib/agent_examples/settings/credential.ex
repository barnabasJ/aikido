defmodule AgentExamples.Settings.Credential do
  @moduledoc "An AshCloak-encrypted provider API key owned by one signed browser identity."
  use Ash.Resource,
    domain: AgentExamples.Settings,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCloak]

  sqlite do
    repo AgentExamples.Settings.Repo
    table "provider_credentials"
  end

  cloak do
    vault AgentExamples.Settings.Vault
    attributes [:api_key]
    decrypt_by_default []
  end

  attributes do
    attribute :owner, :string do
      description "Signed browser identity that owns this credential."
      primary_key? true
      allow_nil? false
    end

    attribute :provider, :string do
      description "Canonical provider family, shared by compatible endpoint variants."
      primary_key? true
      allow_nil? false
    end

    attribute :api_key, :string do
      description "Provider secret encrypted by AshCloak and loaded only for model requests."
      allow_nil? false
      sensitive? true
    end
  end

  actions do
    defaults [:read]

    create :save do
      accept [:owner, :provider]
      argument :api_key, :string, allow_nil?: false, sensitive?: true
      change {AshCloak.Changes.Encrypt, field: :api_key}
      upsert? true
      upsert_fields [:encrypted_api_key]
    end
  end
end
