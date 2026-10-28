defmodule Aikido.Actions.Lifecycle.StopSelf do
  @moduledoc """
  Pure reducer that requests this agent's termination with `reason`.

  Returns a `Stop` directive without changing agent state.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    reason = input.arguments[:reason]
    directive = Aikido.Directives.stop(reason)

    Aikido.Types.ActionResult.new(
      changes: nil,
      directives: [directive]
    )
  end
end
