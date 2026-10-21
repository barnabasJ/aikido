defmodule Aikido.Memory.Actions.PutSpace do
  @moduledoc "Replaces a named memory space using the input signal timestamp."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Memory.Spaces.replace_spaces_and_advance_revision(
      input,
      Map.put(input.arguments.state.spaces, input.arguments.space, input.arguments.value)
    )
  end
end
