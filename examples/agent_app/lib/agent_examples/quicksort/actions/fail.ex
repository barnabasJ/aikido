defmodule AgentExamples.Quicksort.Actions.Fail do
  @moduledoc "Marks a partition failed and propagates the missing-child failure toward the root."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    AgentExamples.Quicksort.PartitionTree.fail_partition(
      input.arguments.state,
      input.context.aikido.signal.data,
      input.context.aikido
    )
  end
end
