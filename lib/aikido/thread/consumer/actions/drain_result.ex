defmodule Aikido.Thread.Consumer.Actions.DrainResult do
  @moduledoc "Expose a drain result to ordinary signal subscribers without changing its adopted state."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _options, _context), do: Aikido.Types.ActionResult.new(changes: nil)
end
