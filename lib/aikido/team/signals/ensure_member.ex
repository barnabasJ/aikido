defmodule Aikido.Team.Signals.EnsureMember do
  @moduledoc "Typed payload for `aikido.ash.team.ensure_member`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.ensure_member"

    schema do
      attribute :member, :term do
        description "Topology name of the member to operate on."
        allow_nil? false
      end
    end
  end
end
