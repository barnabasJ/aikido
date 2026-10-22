defmodule AgentExamples.Settings.Preference do
  @moduledoc "A browser's selected provider, model and live/offline mode, retained across restarts."
  use Ash.Resource, domain: AgentExamples.Settings, data_layer: AshSqlite.DataLayer

  sqlite do
    repo AgentExamples.Settings.Repo
    table "provider_preferences"
  end

  attributes do
    attribute :owner, :string do
      description "Signed browser identity that owns these settings."
      primary_key? true
      allow_nil? false
    end

    attribute :mode, AgentExamples.Settings.Types.Mode do
      description "Whether examples use the offline model or the saved live provider."
      allow_nil? false
    end

    attribute :provider, :string do
      description "Native ReqLLM provider selected by this browser."
      allow_nil? false
    end

    attribute :model, :string do
      description "Model identifier passed to the selected native provider."
      allow_nil? false
    end

    attribute :key_configured?, :boolean do
      description "Whether a credential has been saved for the selected provider."
      allow_nil? false
      default false
    end
  end

  actions do
    defaults [:read]

    create :save do
      accept [:owner, :mode, :provider, :model, :key_configured?]
      upsert? true
      upsert_fields [:mode, :provider, :model, :key_configured?]
    end
  end
end
