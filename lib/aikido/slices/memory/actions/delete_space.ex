defmodule Aikido.Slices.Memory.Actions.DeleteSpace do
  @moduledoc "Deletes a named memory space using the input signal timestamp."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.Memory.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    name = input.arguments[:space]
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Memory.delete_space(memory, name, ActionOptions.from_input(input)),
      directives: []
    )
  end
end
