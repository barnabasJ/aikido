defmodule Aikido.Team.Signals.AckRoster do
  @moduledoc "Typed payload for `aikido.ash.team.ack_roster`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.ack_roster"

    schema do
      attribute :consumer, Aikido.Agent.Reference do
        description "Durable consumer address authorized by the source."
        allow_nil? false
      end

      attribute :path, :atom do
        description "Source mount receiving this request."
        default :team
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
