defmodule Aikido.Memory.Actions.UpdateSpace do
  @moduledoc "Updates an existing memory space using the supplied replacement value."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    with {:ok, existing} <- Aikido.Memory.Spaces.fetch(input) do
      replacement = %{input.arguments.value | rev: existing.rev + 1}

      Aikido.Memory.Spaces.replace_spaces_and_advance_revision(
        input,
        Map.put(input.arguments.state.spaces, input.arguments.space, replacement)
      )
    end
  end
end
