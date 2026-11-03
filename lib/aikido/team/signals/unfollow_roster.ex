defmodule Aikido.Team.Signals.UnfollowRoster do
  @moduledoc "Typed payload for `aikido.ash.team.unfollow_roster`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.unfollow_roster"

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
    end
  end
end
