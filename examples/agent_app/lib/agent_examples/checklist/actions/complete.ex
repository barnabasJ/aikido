defmodule AgentExamples.Checklist.Actions.Complete do
  @moduledoc "Removes a pending item and increments the completed count."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    %{state: state, item: item} = input.arguments

    if item in state.items do
      Aikido.Types.ActionResult.new(
        state: %{state | items: List.delete(state.items, item), completed: state.completed + 1}
      )
    else
      {:error, "Unknown checklist item: #{item}"}
    end
  end
end
