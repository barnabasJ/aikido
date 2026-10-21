defmodule Aikido.Memory.Actions.PutSpace do
  @moduledoc "Replaces a named memory space using the input signal timestamp."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Memory.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    name = input.arguments[:space]
    space = input.arguments.value
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: Aikido.Memory.Slice.put_space(memory, name, space, ActionOptions.from_input(input)),
      directives: []
    )
  end
end
