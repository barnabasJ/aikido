defmodule Aikido.Thread.Signals.Unavailable do
  @moduledoc "A journal request could not reach a running source; no replay or commit is implied."
  use Aikido.Signal

  signal do
    type "aikido.thread.unavailable"

    schema do
      attribute :source, Aikido.Agent.Reference do
        description "Durable source which currently has no running incarnation."
        allow_nil? false
      end

      attribute :path, :atom do
        description "Requested source mount."
        allow_nil? false
      end

      attribute :request_type, :string do
        description "Follow, Ack or Unfollow request that could not be delivered."
        allow_nil? false
      end

      attribute :channel, Aikido.Thread.Types.Channel do
        description "Unavailable Thread or Team roster request."
        allow_nil? false
      end
    end
  end
end
