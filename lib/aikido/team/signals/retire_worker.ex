defmodule Aikido.Team.Signals.RetireWorker do
  @moduledoc "Typed payload for `aikido.ash.team.retire_worker`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.retire_worker"

    schema do
      attribute :member, :term do
        description "Task-scoped member to retire when no work remains."
      end
    end
  end
end
