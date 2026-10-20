defmodule AgentExamples.Checklist.Add do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{state | items: state.items ++ [input.arguments.item]})
  end
end

defmodule AgentExamples.Checklist.Complete do
  @moduledoc false
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
