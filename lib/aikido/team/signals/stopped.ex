defmodule Aikido.Team.Signals.Stopped do
  @moduledoc "Typed payload for `aikido.ash.team.stopped`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.stopped"

    schema do
      attribute :member, :term do
        description "Topology name of the stopped member."
      end

      attribute :operation_id, :string do
        description "Lifecycle operation that requested the stop."
      end

      attribute :pid, :term do
        description "Member process that was stopped."
      end

      attribute :result, :term do
        description "Result returned by the stop task."
      end
    end
  end
end
