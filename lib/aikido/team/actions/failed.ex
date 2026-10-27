defmodule Aikido.Team.Actions.Failed do
  @moduledoc "Fails the current correlated lifecycle operation and notifies pending task callers."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, _config} = ActionAdapter.unpack_team_action(input)

    signal.data
    |> TopologyOperation.fail_operation_and_pending_tasks(state, context)
    |> ActionAdapter.to_action_result()
  end
end
