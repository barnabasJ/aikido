defmodule Aikido.Thread.Consumer.Signals.RequestTimeout do
  @moduledoc "Typed payload for `aikido.thread.consumer.request_timeout`."
  use Aikido.Signal

  signal do
    type "aikido.thread.consumer.request_timeout"

    schema do
      attribute :source, Aikido.Agent.Reference do
        description "Source address of the outstanding demand."
        allow_nil? false
      end

      attribute :path, :atom do
        description "Outstanding source mount."
        allow_nil? false
      end

      attribute :channel, Aikido.Thread.Types.Channel do
        description "Outstanding journal channel."
        allow_nil? false
      end

      attribute :request_id, :string do
        description "Request still awaiting a source reply."
        allow_nil? false
      end
    end
  end
end
