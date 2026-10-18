defmodule Aikido.Ash.Team.State do
  @moduledoc "Action-owned team topology, lifecycle progress, and task receipts."
  use Ash.TypedStruct

  typed_struct do
    field :topology, Aikido.Ash.Team.Topology,
      allow_nil?: false,
      default: %Aikido.Ash.Team.Topology{}

    field :members, :map, allow_nil?: false, default: %{}
    field :incarnations, :map, allow_nil?: false, default: %{}
    field :paused, :map, allow_nil?: false, default: %{}
    field :failures, :map, allow_nil?: false, default: %{}
    field :tasks, :map, allow_nil?: false, default: %{}

    field :operation, :map,
      allow_nil?: false,
      default: %{
        id: nil,
        status: :idle,
        remaining: [],
        awaiting: nil,
        started: [],
        stopped: [],
        error: nil
      }
  end
end
