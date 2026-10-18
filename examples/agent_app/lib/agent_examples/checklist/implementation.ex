defmodule AgentExamples.Checklist.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, [action: :add], _context) do
    state = input.arguments.state
    Aikido.ActionResult.new(state: %{state | items: state.items ++ [input.arguments.item]})
  end

  @impl true
  def run(input, [action: :complete], _context) do
    %{state: state, item: item} = input.arguments

    if item in state.items do
      Aikido.ActionResult.new(
        state: %{state | items: List.delete(state.items, item), completed: state.completed + 1}
      )
    else
      {:error, "Unknown checklist item: #{item}"}
    end
  end
end
