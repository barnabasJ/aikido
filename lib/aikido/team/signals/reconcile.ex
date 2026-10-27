defmodule Aikido.Team.Signals.Reconcile do
  @moduledoc "Typed payload for `aikido.ash.team.reconcile`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.reconcile"

    schema do
    end
  end
end
