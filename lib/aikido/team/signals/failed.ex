defmodule Aikido.Team.Signals.Failed do
  @moduledoc "Typed payload for `aikido.ash.team.failed`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.failed"

    schema do
      attribute :member, :term do
        description "Topology name of the member whose lifecycle operation failed."
      end

      attribute :operation_id, :string do
        description "Lifecycle operation that failed."
      end

      attribute :reason, :term do
        description "Failure returned by the supervised lifecycle task."
      end

      attribute :pid, :term do
        description "Member process involved in the failed operation."
      end
    end
  end
end
