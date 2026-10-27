defmodule Aikido.Team.Signals.AddMember do
  @moduledoc "Typed payload for `aikido.ash.team.add_member`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.add_member"

    schema do
      attribute :member, :term do
        description "Topology name of the member to operate on."
        allow_nil? false
      end

      attribute :resource, :atom do
        description "Agent resource used for a member created without a worker template."
      end

      attribute :template, :atom do
        description "Configured worker template used to create this member."
      end

      attribute :initial_state, :map do
        description "Initial attributes supplied when activating the member."
        default %{}
      end

      attribute :owner, :term do
        description "Owning topology member; nil assigns ownership to the team."
      end

      attribute :depends_on, {:array, :term} do
        description "Members that must be active before this member starts."
        default []
      end

      attribute :activation, Aikido.Team.Types.Activation do
        description "Whether this member starts immediately or waits for demand."
        default :eager
      end
    end
  end
end
