defmodule Aikido.Memory.Actions.DeleteFromSpace do
  @moduledoc "Removes a key from a named memory space."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Memory.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    name = input.arguments[:space]
    key = input.arguments[:key]
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state:
        Aikido.Memory.Slice.delete_from_space(memory, name, key, ActionOptions.from_input(input)),
      directives: []
    )
  end
end
