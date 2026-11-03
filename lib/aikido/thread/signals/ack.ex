defmodule Aikido.Thread.Signals.Ack do
  @moduledoc "Typed payload for `aikido.thread.ack`."
  use Aikido.Signal

  signal do
    type "aikido.thread.ack"

    schema do
      attribute :consumer, Aikido.Agent.Reference do
        description "Durable consumer address authorized by the source."
        allow_nil? false
      end

      attribute :path, :atom do
        description "Source mount receiving this request."
        default :thread
        allow_nil? false
      end

      attribute :batch_id, :string do
        description "Exact offered batch identity."
        allow_nil? false
      end

      attribute :cursor, Aikido.Thread.Types.Cursor do
        description "Last offered sequence committed by the consumer."
        allow_nil? false
      end
    end
  end
end
