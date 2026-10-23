defmodule Aikido.Team.Actions.OperationCompleted do
  @moduledoc "Acknowledges lifecycle completion while preserving the completed team state."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    {_signal, state, context, _config} = Aikido.Team.ActionAdapter.unpack_team_action(input)

    {state, directives} = Aikido.Team.TopologyOperation.release_queued_operations(state, context)
    Aikido.Types.ActionResult.new(state: state, directives: directives)
  end
end
