defmodule Aikido.Team.Types.Coordination do
  @moduledoc "Finite coordinator view; no agent history, startup options or execution authority."
  use Ash.TypedStruct

  typed_struct do
    field :coordinator, Aikido.Agent.Reference do
      description "Durable address of the Team that owns this view."
      allow_nil? false
    end

    field :requester, :term do
      description "Member whose task ledger is visible, or the explicit coordinator :self."
      allow_nil? false
    end

    field :members, {:array, Aikido.Team.Types.CoordinationMember} do
      description "Authored names and aggregate availability, excluding member startup data."
      default []
      allow_nil? false
    end

    field :tasks, {:array, Aikido.Team.Types.CoordinationTask} do
      description "Only tasks belonging to this requester, including pending activation."
      default []
      allow_nil? false
    end
  end
end
