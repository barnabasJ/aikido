defmodule Aikido.Team.Actions.OperationCompleted do
  @moduledoc "Acknowledges lifecycle completion while preserving the completed team state."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state)
  end
end
