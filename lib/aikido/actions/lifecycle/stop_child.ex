defmodule Aikido.Actions.Lifecycle.StopChild do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    tag = input.arguments[:tag]
    reason = input.arguments[:reason]
    directive = Aikido.Directives.stop_child(tag, reason)

    Aikido.ActionResult.new(
      state: %{stopping_child: tag, reason: reason},
      directives: [directive]
    )
  end
end
