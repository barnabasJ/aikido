defmodule Aikido.Team.Signals.Started do
  @moduledoc "Typed payload for `aikido.ash.team.started`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.started"

    schema do
      attribute :reference, Aikido.Agent.Reference do
        description "Exact native address retained for cleanup of a late activation."
      end

      attribute :member, :term do
        description "Topology name of the activated member."
      end

      attribute :operation_id, :string do
        description "Lifecycle operation that requested activation."
      end

      attribute :result, :term do
        description "Activated member process returned by the supervised task."
      end
    end
  end
end
