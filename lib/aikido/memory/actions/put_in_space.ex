defmodule Aikido.Memory.Actions.PutInSpace do
  @moduledoc "Stores a key and value in a named memory space."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Memory.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    name = input.arguments[:space]
    key = input.arguments[:key]
    value = input.arguments[:value]
    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state:
        Aikido.Memory.Slice.put_in_space(
          memory,
          name,
          key,
          value,
          ActionOptions.from_input(input)
        ),
      directives: []
    )
  end
end
