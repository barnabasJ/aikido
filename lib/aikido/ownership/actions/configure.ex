defmodule Aikido.Ownership.Actions.Configure do
  @moduledoc "Adopts startup ownership options and requests the parent's monitor."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ownership.ParentBinding

  @impl true
  def run(input, _, _) do
    state = %{input.arguments.state | on_parent_death: input.arguments.on_parent_death}

    case Map.get(input.arguments, :parent) do
      nil ->
        Aikido.Types.ActionResult.new(changes: %{on_parent_death: state.on_parent_death})

      parent ->
        with {:ok, state} <- ParentBinding.attach(state, parent, input.context.aikido.agent_pid) do
          Aikido.Types.ActionResult.new(
            changes: %{
              on_parent_death: state.on_parent_death,
              parent: state.parent,
              orphaned_from: nil,
              parent_monitor: nil
            },
            directives: ParentBinding.monitor(state)
          )
        end
    end
  end
end
