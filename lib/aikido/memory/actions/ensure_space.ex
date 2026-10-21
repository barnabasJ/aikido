defmodule Aikido.Memory.Actions.EnsureSpace do
  @moduledoc "Creates a missing memory space from its native default while preserving an existing space."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    name = input.arguments.space

    if Map.get(state.spaces, name) do
      Aikido.Types.ActionResult.new(state: state)
    else
      data =
        case input.arguments.default do
          %Ash.Union{value: value} -> value
          nil -> nil
        end

      with {:ok, space} <- Aikido.Memory.Types.Space.new(data: data) do
        Aikido.Memory.Spaces.replace_spaces_and_advance_revision(
          input,
          Map.put(state.spaces, name, space)
        )
      end
    end
  end
end
