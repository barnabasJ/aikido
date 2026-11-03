defmodule Aikido.Thread.Consumer.Signals.Failed do
  @moduledoc "Typed payload for `aikido.thread.consumer.failed`."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.failed"

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
        description "Offered range whose external write failed."
        allow_nil? false
      end

      attribute :retry_after_ms, :integer do
        description "Application-classified transient failure delay; nil requires manual intervention."
        constraints min: 1, max: 3_600_000
      end

      attribute :message, :string do
        description "Public write error, with secrets masked by the application."
        allow_nil? false
        constraints max_length: 4096
      end
    end
  end
end
