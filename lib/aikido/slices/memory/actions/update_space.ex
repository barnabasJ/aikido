defmodule Aikido.Slices.Memory.Actions.UpdateSpace do
  @moduledoc "Updates an existing memory space using the supplied replacement value."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.Memory.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    name = input.arguments[:space]
    new_space = input.arguments.value
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state:
        Aikido.Slices.Memory.update_space(
          memory,
          name,
          fn _existing -> new_space end,
          ActionOptions.from_input(input)
        ),
      directives: []
    )
  end
end
