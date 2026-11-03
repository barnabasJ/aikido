defmodule Aikido.Thread.Signals.Batch do
  @moduledoc "Typed payload for `aikido.thread.batch`."
  use Aikido.Signal

  signal do
    type "aikido.thread.batch"

    schema do
      attribute :request_id, :string do
        description "Follow request selecting this response; source gap notices may reference another source turn."
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
        description "Offered immutable sequence range."
        allow_nil? false
      end

      attribute :entries, {:array, Aikido.Thread.Types.Entry} do
        description "Original entries, preserving IDs, timestamps and signal refs."
        allow_nil? false
      end
    end
  end
end
