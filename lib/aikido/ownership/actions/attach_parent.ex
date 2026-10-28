defmodule Aikido.Ownership.Actions.AttachParent do
  @moduledoc "Binds an unattached agent to a parent and announces the new attachment."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ownership.ParentBinding

  @impl true
  def run(input, _, _) do
    state = input.arguments.state
    context = input.context.aikido

    if input.arguments.initial_only? and (state.parent || state.orphaned_from) do
      Aikido.Types.ActionResult.new(changes: nil)
    else
      with {:ok, state} <- ParentBinding.attach(state, input.arguments.parent, context.agent_pid) do
        Aikido.Types.ActionResult.new(
          changes: %{parent: state.parent, orphaned_from: nil, parent_monitor: nil},
          directives: ParentBinding.monitor(state) ++ ParentBinding.announce(state, context)
        )
      end
    end
  end
end
