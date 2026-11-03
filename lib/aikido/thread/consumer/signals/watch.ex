defmodule Aikido.Thread.Consumer.Signals.Watch do
  @moduledoc "Typed payload for `aikido.thread.consumer.watch`."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.watch"

    schema do
      attribute :source, Aikido.Agent.Reference do
        description "Durable journal source address."
        allow_nil? false
      end

      attribute :path, :atom do
        description "Source slice mount."
        default :thread
        allow_nil? false
      end

      attribute :channel, Aikido.Thread.Types.Channel do
        description "Thread entries or retained Team membership."
        default :thread
        allow_nil? false
      end

      attribute :after, Aikido.Thread.Types.Cursor do
        description "Known SQL checkpoint; nil preserves an existing checkpoint unless reset is explicit."
      end

      attribute :reset?, :boolean do
        description "Explicitly accept a new retained beginning after a gap."
        default false
        allow_nil? false
      end
    end
  end
end
