defmodule AgentExamples.Checklist.Add do
  @moduledoc "Appends an item to the pending checklist."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{state | items: state.items ++ [input.arguments.item]})
  end
end
