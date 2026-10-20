defmodule Aikido.Ash.Team.Actions.Stopped do
  @moduledoc "Removes a correlated stopped member and advances the lifecycle plan."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Team.{Inputs, Operation}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(reduce(signal.data, state, context, config))
  end

  defp reduce(%{member: name, operation_id: id}, state, context, config) do
    if Operation.awaited?(state, id, {:stop, name}) do
      state = %{
        state
        | members: Map.delete(state.members, name),
          incarnations: Map.delete(state.incarnations, name)
      }

      state = update_in(state.operation.stopped, &(&1 ++ [name]))
      Operation.advance(state, context, config)
    else
      {:ok, state, []}
    end
  end
end
