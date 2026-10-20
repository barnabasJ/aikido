defmodule Aikido.Actions.Lifecycle.StopSelf do
  @moduledoc """
  Pure reducer that requests this agent's termination with `reason`.

  Returns the supplied `state` and a `Stop` directive for the runtime to execute.
  """
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
