defmodule Aikido.Team.Actions.Timeout do
  @moduledoc "Fails a correlated lifecycle operation when its completion deadline expires."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, _config} = ActionAdapter.unpack_team_action(input)

    %{operation_id: signal.data.operation_id, reason: :timeout}
    |> TopologyOperation.fail_operation_and_pending_tasks(state, context)
    |> ActionAdapter.to_action_result(state)
  end
end
