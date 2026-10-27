defmodule AgentExamples.Quicksort.Actions.RetryChild do
  @moduledoc "Reactivates a pending partition unless readiness, completion or cancellation superseded its retry."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    tag = input.arguments.tag

    pending? =
      state.status == :sorting && Map.has_key?(state.partitions, tag) &&
        !Map.has_key?(state.started_children, tag) && !Map.has_key?(state.results, tag) &&
        state.child_attempts[tag] == input.arguments.attempt

    directives =
      if pending?,
        do: [AgentExamples.Quicksort.PartitionTree.spawn_partition(state, tag)],
        else: []

    Aikido.Types.ActionResult.new(state: state, directives: directives)
  end
end
