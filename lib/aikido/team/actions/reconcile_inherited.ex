defmodule Aikido.Team.Actions.ReconcileInherited do
  @moduledoc "Reconcile explicitly opted-in own fields across the running native team tree."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation}

  @impl true
  def run(input, _options, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    TopologyOperation.reconcile_inherited(signal, state, context, config)
    |> ActionAdapter.to_action_result(state, context)
  end
end
