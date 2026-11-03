defmodule Aikido.Team.Types.RosterBootstrap do
  @moduledoc "Typed initial roster captured in the same source turn as follower registration."
  use Ash.TypedStruct

  typed_struct do
    field :members, {:array, Aikido.Team.Types.Membership} do
      description "Current declared membership and recorded activation state."
      default []
      allow_nil? false
    end
  end
end
