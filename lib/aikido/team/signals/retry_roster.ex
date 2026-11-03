defmodule Aikido.Team.Signals.RetryRoster do
  @moduledoc "Typed payload for `aikido.ash.team.retry_roster`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.retry_roster"

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

      attribute :notice_id, :string do
        description "Current roster availability notice to retry."
        allow_nil? false
      end

      attribute :generation, :string do
        description "Roster generation containing that batch."
        allow_nil? false
      end
    end
  end
end
