defmodule Aikido.Thread.Consumer.Signals.RetryDue do
  @moduledoc "A correlated persisted retry deadline became due."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.retry_due"

    schema do
      attribute :source, Aikido.Agent.Reference do
        description "Durable journal source address."
        allow_nil? false
      end

      attribute :path, :atom do
        description "Source slice mount."
        allow_nil? false
      end

      attribute :channel, Aikido.Thread.Types.Channel do
        description "Thread entries or retained membership."
        allow_nil? false
      end

      attribute :retry_id, :string do
        description "Failure signal identity whose deadline is being delivered."
        allow_nil? false
      end

      attribute :generation, :string do
        description "Generation of the failed sink batch."
        allow_nil? false
      end
    end
  end
end
