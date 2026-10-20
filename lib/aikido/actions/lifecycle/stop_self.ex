defmodule Aikido.Actions.Lifecycle.StopSelf do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    reason = input.arguments[:reason]
    directive = Aikido.Directives.stop(reason)

    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [directive]
    )
  end
end
