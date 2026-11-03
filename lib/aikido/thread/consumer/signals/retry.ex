defmodule Aikido.Thread.Consumer.Signals.Retry do
  @moduledoc "Typed payload for `aikido.thread.consumer.retry`."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.retry"

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
    end
  end
end
