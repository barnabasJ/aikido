defmodule Aikido.Actions.Lifecycle.SpawnChild do
  @moduledoc """
  Pure reducer that requests a child agent using `agent_module` and `tag`.

  Returns the supplied `state` and a `SpawnAgent` directive carrying the child's
  `initial_state`, `meta` and `restart?` policy. The directive performs activation.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    mod = input.arguments[:agent_module]
    tag = input.arguments[:tag]
    state = input.arguments[:initial_state]
    meta = input.arguments[:meta]
    restart? = input.arguments[:restart?]

    opts =
      if state == %{} do
        %{}
      else
        %{initial_state: state}
      end

    directive =
      Aikido.Directives.spawn_agent(mod, tag, opts: opts, meta: meta, restart?: restart?)

    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [directive])
  end
end
