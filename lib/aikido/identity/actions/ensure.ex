defmodule Aikido.Identity.Actions.Ensure do
  @moduledoc "Preserves the initialized identity without changing its state."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [])
  end
end
