defmodule Aikido.Thread.Consumer.Signals.Work do
  @moduledoc "Typed payload for `aikido.thread.consumer.work`."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.work"

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

      attribute :batch, Aikido.Thread.Types.Batch do
        description "Exactly one reserved SQL-work range."
        allow_nil? false
      end

      attribute :metadata, :map do
        description "Confirmed source Thread metadata carried as data; applications retain their own authorization and masking."
        default %{}
        allow_nil? false
      end

      attribute :retry_attempt, :integer do
        description "Automatic sink retries consumed for this source before the offered work."
        default 0
        allow_nil? false
        constraints min: 0
      end

      attribute :entries, {:array, Aikido.Thread.Types.Entry} do
        description "Original immutable entries; the application masks and writes these in its scoped effect."
        allow_nil? false
      end
    end
  end
end
