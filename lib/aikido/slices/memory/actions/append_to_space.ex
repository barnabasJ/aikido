defmodule Aikido.Slices.Memory.Actions.AppendToSpace do
  @moduledoc "Appends an item to a named list memory space."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.Memory.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    name = input.arguments[:space]
    item = input.arguments[:item]
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state:
        Aikido.Slices.Memory.append_to_space(memory, name, item, ActionOptions.from_input(input)),
      directives: []
    )
  end
end
