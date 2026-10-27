defmodule Aikido.Team.Actions.Cleanup do
  @moduledoc "Acknowledges completion of cleanup work without changing team state."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state)
  end
end
