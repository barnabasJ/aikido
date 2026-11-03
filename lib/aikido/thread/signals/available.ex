defmodule Aikido.Thread.Signals.Available do
  @moduledoc "Typed payload for `aikido.thread.available`."
  use Aikido.Signal

  signal do
    type "aikido.thread.available"

    schema do
      attribute :request_id, :string do
        description "Originating source turn; only a matching Follow request can release waiting consumer credit."
        allow_nil? false
      end

      attribute :source, Aikido.Agent.Reference do
        description "Durable source identity."
        allow_nil? false
      end

      attribute :consumer, Aikido.Agent.Reference do
        description "Durable consumer address authorized by the source."
        allow_nil? false
      end

      attribute :path, :atom do
        description "Source mount receiving this request."
        default :thread
        allow_nil? false
      end

      attribute :channel, Aikido.Thread.Types.Channel do
        description "Owning Thread or Team roster journal."
        allow_nil? false
      end

      attribute :batch, Aikido.Thread.Types.Batch do
        description "Previously offered unacknowledged range, if any."
      end

      attribute :cursor, Aikido.Thread.Types.Cursor do
        description "Current source high-water mark; no entries or private content are included."
        allow_nil? false
      end

      attribute :pending?, :boolean do
        description "Whether the consumer's SQL cursor is behind the source."
        allow_nil? false
      end
    end
  end
end
