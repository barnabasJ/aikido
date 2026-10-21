defmodule Aikido.Memory.Actions.AppendToSpace do
  @moduledoc "Appends an item to a named list memory space."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Memory.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    name = input.arguments[:space]
    item = input.arguments[:item]
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state:
        Aikido.Memory.Slice.append_to_space(memory, name, item, ActionOptions.from_input(input)),
      directives: []
    )
  end
end
