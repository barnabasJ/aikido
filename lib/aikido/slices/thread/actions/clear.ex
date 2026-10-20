defmodule Aikido.Slices.Thread.Actions.Clear do
  @moduledoc "Clears thread entries using the input signal timestamp."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.Thread.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: Aikido.Slices.Thread.clear(input.arguments.state, ActionOptions.from_input(input)),
      directives: []
    )
  end
end
