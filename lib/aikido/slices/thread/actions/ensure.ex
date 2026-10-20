defmodule Aikido.Slices.Thread.Actions.Ensure do
  @moduledoc "Preserves the initialized thread and its existing entries."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [])
  end
end
