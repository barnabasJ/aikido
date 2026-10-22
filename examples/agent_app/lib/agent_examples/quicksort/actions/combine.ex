defmodule AgentExamples.Quicksort.Actions.Combine do
  @moduledoc "Records a sorted child partition and combines both sides when ready."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    state = %{
      state
      | results: Map.put(state.results, input.arguments.branch, input.arguments.numbers)
    }

    AgentExamples.Quicksort.PartitionTree.finish_or_wait(state, input.context.aikido)
  end
end
