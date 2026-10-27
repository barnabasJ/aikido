defmodule Aikido.Team.Signals.RemoveMember do
  @moduledoc "Typed payload for `aikido.ash.team.remove_member`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.remove_member"

    schema do
      attribute :member, :term do
        description "Topology name of the member to operate on."
        allow_nil? false
      end

      attribute :cascade?, :boolean do
        description "Whether removing a member also removes its dependent members."
        default false
      end
    end
  end
end
