defmodule AgentExamples.Quicksort.Actions.Partition do
  @moduledoc "Splits input around a pivot and spawns agents for every nonempty smaller/larger partition."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    if state.status != :idle do
      {:error, "Start a new sorting tree for another input."}
    else
      {pivot, equal, partitions} =
        AgentExamples.Quicksort.PartitionTree.split(input.arguments.numbers)

      state = %{
        state
        | numbers: input.arguments.numbers,
          topic: input.arguments.topic,
          pivot: pivot,
          equal: equal,
          partitions: partitions,
          status: :sorting
      }

      context = input.context.aikido

      if map_size(partitions) == 0 do
        AgentExamples.Quicksort.PartitionTree.finish_or_wait(state, context)
      else
        Aikido.Types.ActionResult.new(
          state: state,
          directives: [
            AgentExamples.Quicksort.PartitionTree.progress(state, context)
            | AgentExamples.Quicksort.PartitionTree.spawn_partitions(state)
          ]
        )
      end
    end
  end
end
