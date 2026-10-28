defmodule Aikido.Team.Actions.Stopped do
  @moduledoc "Removes a correlated stopped member and advances the lifecycle plan."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TopologyOperation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    ActionAdapter.to_action_result(
      remove_stopped_member(signal.data, state, context, config),
      state
    )
  end

  defp remove_stopped_member(%{member: name, operation_id: id}, state, context, config) do
    if TopologyOperation.awaited?(state, id, {:stop, name}) do
      state = %{
        state
        | members: Map.delete(state.members, name),
          incarnations: Map.delete(state.incarnations, name)
      }

      state = update_in(state.operation.stopped, &(&1 ++ [name]))
      TopologyOperation.advance_member_lifecycle(state, context, config)
    else
      {:ok, state, []}
    end
  end
end
