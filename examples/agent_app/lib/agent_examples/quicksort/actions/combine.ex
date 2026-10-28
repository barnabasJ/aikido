defmodule AgentExamples.Quicksort.Actions.Combine do
  @moduledoc "Records a sorted child result, retires that worker and combines both sides when ready."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    if state.status == :sorting do
      results = Map.put(state.results, input.arguments.branch, input.arguments.numbers)
      state = %{state | results: results}

      with {:ok, result} <-
             AgentExamples.Quicksort.PartitionTree.finish_or_wait(
               state,
               input.context.aikido,
               %{results: results}
             ) do
        {:ok,
         %{
           result
           | directives: [
               %Aikido.Directives.StopChild{tag: input.arguments.branch} | result.directives
             ]
         }}
      end
    else
      Aikido.Types.ActionResult.new(changes: nil)
    end
  end
end
