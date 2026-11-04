defmodule Aikido.Team.Signals.ReconcileInherited do
  @moduledoc "Reconcile explicitly declared inherited configuration across current team members."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.reconcile_inherited"

    schema do
    end
  end
end
