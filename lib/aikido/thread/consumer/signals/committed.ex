defmodule Aikido.Thread.Consumer.Signals.Committed do
  @moduledoc """
  Application assertion that an offered batch committed to its external sink.

  Native consumer credit correlation checks the exact active range. The owning
  agent's Ash policies must authorize the actual writer; this signal is not
  independent proof of an external database transaction. Applications may send
  it manually or return it from AsyncTask after successful commit.
  """
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.committed"

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
        description "Offered range whose external write committed."
        allow_nil? false
      end
    end
  end
end
