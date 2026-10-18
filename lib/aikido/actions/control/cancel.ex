defmodule Aikido.Actions.Control.Cancel do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    reason = input.arguments[:reason]

    Aikido.ActionResult.new(
      state: %{status: :failed, error: {:cancelled, reason}},
      directives: []
    )
  end
end
