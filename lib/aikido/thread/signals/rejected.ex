defmodule Aikido.Thread.Signals.Rejected do
  @moduledoc "An owning source action rejected a journal request before replay was accepted."
  use Aikido.Signal

  signal do
    type "aikido.thread.rejected"

    schema do
      attribute :source, Aikido.Agent.Reference do
        description "Actual source resource and durable identity."
        allow_nil? false
      end

      attribute :consumer, Aikido.Agent.Reference do
        description "Actual requesting consumer from runtime delivery provenance."
        allow_nil? false
      end

      attribute :path, :atom do
        description "Requested source mount."
        allow_nil? false
      end

      attribute :channel, Aikido.Thread.Types.Channel do
        description "Thread or Team roster request that was rejected."
        allow_nil? false
      end

      attribute :request_id, :string do
        description "Original rejected request envelope identity."
        allow_nil? false
      end

      attribute :request_type, :string do
        description "Native Follow, Ack or Unfollow operation that was rejected."
        allow_nil? false
      end

      attribute :failure, Aikido.Thread.Types.RequestFailure do
        description "Native authorization, input or runtime failure class."
        allow_nil? false
      end

      attribute :message, :string do
        description "Actionable explanation without source state, private scope or credentials."
        allow_nil? false
      end
    end
  end
end
