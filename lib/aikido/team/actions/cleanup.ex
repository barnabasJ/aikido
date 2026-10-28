defmodule Aikido.Team.Actions.Cleanup do
  @moduledoc "Acknowledges successful cleanup and reports native cleanup errors without changing team state."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    case input.arguments[:reason] do
      nil -> Aikido.Types.ActionResult.new(changes: nil)
      reason -> {:error, reason}
    end
  end
end
