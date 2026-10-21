defmodule Aikido.Thread.Actions.Clear do
  @moduledoc "Clears thread entries using the input signal timestamp."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Thread.ActionOptions

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: Aikido.Thread.Slice.clear(input.arguments.state, ActionOptions.from_input(input)),
      directives: []
    )
  end
end
