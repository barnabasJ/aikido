defmodule Aikido.Memory.Actions.EnsureSpace do
  @moduledoc "Creates a missing memory space from its native default while preserving an existing space."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Memory.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    name = input.arguments[:space]

    default =
      case input.arguments.default do
        %Ash.Union{value: value} -> value
        nil -> nil
      end

    memory = input.arguments.state

    Aikido.Types.ActionResult.new(
      state:
        Aikido.Memory.Slice.ensure_space(memory, name, default, ActionOptions.from_input(input)),
      directives: []
    )
  end
end
