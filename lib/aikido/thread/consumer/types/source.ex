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

    field :error, :string do
      description "Public request or write failure explanation."
      constraints max_length: 4096
    end
  end
end
