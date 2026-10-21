defmodule Aikido.Memory.Actions.DeleteFromSpace do
  @moduledoc "Removes a key from a named memory space."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    with {:ok, space} <- Aikido.Memory.Spaces.fetch(input, :map) do
      space = %{space | data: Map.delete(space.data, input.arguments.key), rev: space.rev + 1}

      Aikido.Memory.Spaces.commit(
        input,
        Map.put(input.arguments.state.spaces, input.arguments.space, space)
      )
    end
  end
end
