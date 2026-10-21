defmodule Aikido.Memory.Actions.Ensure do
  @moduledoc "Preserves the initialized memory without changing its spaces."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [])
  end
end
