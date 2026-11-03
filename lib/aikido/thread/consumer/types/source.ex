defmodule Aikido.Thread.Consumer.Types.Source do
  @moduledoc "One source checkpoint and coalesced availability; contains no entry payload."
  use Ash.TypedStruct

  typed_struct do
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

    field :cursor, Aikido.Thread.Types.Cursor do
      description "Last committed position, or the explicitly accepted initial replay baseline before any SQL work."
    end

    field :head, Aikido.Thread.Types.Cursor do
      description "Last advertised source position."
    end

    field :status, Aikido.Thread.Consumer.Types.SourceStatus do
      description "Whether demand can proceed or needs intervention."
      default :ready
      allow_nil? false
    end

    field :retired?, :boolean do
      description "Membership ended; retain its checkpoint and explicitly drain or report unavailability."
      default false
      allow_nil? false
    end

    field :retry_attempt, :integer do
      description "Automatic sink retries consumed since successful commit or explicit manual retry."
      default 0
      allow_nil? false
      constraints min: 0
    end

    field :retry_at, :integer do
      description "Persisted UTC millisecond deadline for a pending sink retry."
    end

    field :retry_id, :string do
      description "Failure signal identity correlating the pending retry timer."
    end

    field :retry_generation, :string do
      description "Journal generation whose failed write is being retried."
    end

    field :error, :string do
      description "Public request or write failure explanation."
      constraints max_length: 4096
    end
  end
end
