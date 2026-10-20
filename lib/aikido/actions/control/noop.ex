defmodule Aikido.Actions.Control.Noop do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: %{}, directives: [])
  end
end
