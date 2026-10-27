defmodule Aikido.Team.Actions.ChildStarted do
  @moduledoc "Acknowledges child startup while the correlated activation result owns member adoption."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state)
  end
end
