defmodule Aikido.Team.Signals.ConfigureRosterReplay do
  @moduledoc "Explicitly enable retained roster replay and update its routing metadata."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.configure_roster_replay"

    schema do
      attribute :path, :atom do
        description "Owning Team slice mount."
        default :team
        allow_nil? false
      end

      attribute :metadata, :map do
        description "Routing data merged with existing metadata; grants no read authority."
        default %{}
        allow_nil? false
      end
    end
  end
end
