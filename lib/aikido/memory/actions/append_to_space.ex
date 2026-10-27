defmodule Aikido.Memory.Actions.AppendToSpace do
  @moduledoc "Appends an item to a named list memory space."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    with {:ok, space} <- Aikido.Memory.Spaces.fetch(input, :list) do
      space = %{space | data: space.data ++ [input.arguments.item], rev: space.rev + 1}

      Aikido.Memory.Spaces.replace_spaces_and_advance_revision(
        input,
        Map.put(input.arguments.state.spaces, input.arguments.space, space)
      )
    end
  end
end
