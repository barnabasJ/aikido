defmodule Aikido.Team.Actions.Failed do
  @moduledoc "Fails the current correlated lifecycle operation and notifies pending task callers."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Operation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, _config} = Inputs.unpack_team_action(input)

    signal.data
    |> Operation.fail_operation_and_pending_tasks(state, context)
    |> Inputs.to_action_result()
  end
end
