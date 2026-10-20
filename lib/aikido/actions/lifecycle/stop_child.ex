defmodule Aikido.Actions.Lifecycle.StopChild do
  @moduledoc """
  Pure reducer that requests termination of the child identified by `tag`.

  Preserves `state` and returns a `StopChild` directive carrying the supplied
  `reason`; child signaling and runtime bookkeeping happen outside this reducer.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    tag = input.arguments[:tag]
    reason = input.arguments[:reason]
    directive = Aikido.Directives.stop_child(tag, reason)

    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [directive]
    )
  end
end
