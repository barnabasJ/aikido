defmodule Aikido.Actions.Lifecycle.StopSelf.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    reason = input.arguments[:reason]
    directive = Aikido.Directives.stop(reason)
    Aikido.ActionResult.new(state: %{stopping: true, reason: reason}, directives: [directive])
  end
end
