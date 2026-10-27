defmodule Aikido.Ownership.Actions.Configure do
  @moduledoc "Adopts startup ownership options and requests the parent's monitor."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ownership.ParentBinding

  @impl true
  def run(input, _, _) do
    state = %{input.arguments.state | on_parent_death: input.arguments.on_parent_death}

    case Map.get(input.arguments, :parent) do
      nil ->
        Aikido.Types.ActionResult.new(state: state)

      parent ->
        with {:ok, state} <- ParentBinding.attach(state, parent, input.context.aikido.agent_pid) do
          Aikido.Types.ActionResult.new(state: state, directives: ParentBinding.monitor(state))
        end
    end
  end
end
