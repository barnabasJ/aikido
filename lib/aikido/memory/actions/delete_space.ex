defmodule Aikido.Memory.Actions.DeleteSpace do
  @moduledoc "Deletes a named memory space using the input signal timestamp."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    name = input.arguments.space

    if name in [:world, :tasks] do
      Aikido.Memory.Spaces.error(input, "cannot delete reserved space #{inspect(name)}")
    else
      Aikido.Memory.Spaces.commit(input, Map.delete(input.arguments.state.spaces, name))
    end
  end
end
