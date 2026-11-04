defmodule Aikido.Team.Actions.Inherited do
  @moduledoc "Advance a tracked inheritance step only after the runtime verifies its actual member."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation}

  @impl true
  def run(input, _options, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    TopologyOperation.inherited(signal.data, state, context, config)
    |> ActionAdapter.to_action_result(state, context)
  end
end
