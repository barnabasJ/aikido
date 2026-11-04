defmodule Aikido.Team.Actions.Failed do
  @moduledoc "Fails the current correlated lifecycle operation and notifies pending task callers."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, _config} = ActionAdapter.unpack_team_action(input)

    stop_failure? =
      signal.data.operation_id == state.operation.id &&
        match?({:stop, _}, state.operation.awaiting)

    if stop_failure? &&
         !match?(%{protocol: Aikido.Team.Delivery, kind: :stop_result}, context[:__delivery__]) do
      {:error, Ash.Error.Forbidden.exception([])}
    else
      signal.data
      |> TopologyOperation.fail_operation_and_pending_tasks(state, context)
      |> ActionAdapter.to_action_result(state, context)
    end
  end
end
