defmodule Aikido.Team.Actions.Stopped do
  @moduledoc "Removes a correlated stopped member and advances the lifecycle plan."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Operation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.unpack_team_action(input)
    Inputs.to_action_result(remove_stopped_member(signal.data, state, context, config))
  end

  defp remove_stopped_member(%{member: name, operation_id: id}, state, context, config) do
    if Operation.awaited?(state, id, {:stop, name}) do
      state = %{
        state
        | members: Map.delete(state.members, name),
          incarnations: Map.delete(state.incarnations, name)
      }

      state = update_in(state.operation.stopped, &(&1 ++ [name]))
      Operation.advance_member_lifecycle(state, context, config)
    else
      {:ok, state, []}
    end
  end
end
