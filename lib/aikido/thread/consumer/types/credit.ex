defmodule Aikido.Thread.Consumer.Types.Credit do
  @moduledoc "One global demand or SQL-work slot; no entries are retained in the credit."
  use Ash.TypedStruct

  typed_struct do
    field :id, :string do
      description "Consumer request identity."
      allow_nil? false
    end

    field :source, Aikido.Agent.Reference do
      description "Durable journal source address."
      allow_nil? false
    end

    field :path, :atom do
      description "Source slice mount."
      default :thread
      allow_nil? false
    end

    field :channel, Aikido.Thread.Types.Channel do
      description "Thread entries or retained Team membership."
      default :thread
      allow_nil? false
    end

    field :phase, Aikido.Thread.Consumer.Types.CreditPhase do
      description "Awaiting a batch or awaiting the application SQL commit."
      default :requesting
      allow_nil? false
    end

    field :batch, Aikido.Thread.Types.Batch do
      description "Exact SQL-work range when phase is writing."
    end
  end
end
