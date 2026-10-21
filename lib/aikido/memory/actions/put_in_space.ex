defmodule Aikido.Memory.Actions.PutInSpace do
  @moduledoc "Stores a key and value in a named memory space."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    with {:ok, space} <- Aikido.Memory.Spaces.fetch(input, :map) do
      space = %{
        space
        | data: Map.put(space.data, input.arguments.key, input.arguments.value),
          rev: space.rev + 1
      }

      Aikido.Memory.Spaces.commit(
        input,
        Map.put(input.arguments.state.spaces, input.arguments.space, space)
      )
    end
  end
end
