defmodule AgentExamples.Quicksort.Actions.ScheduleChildRetry do
  @moduledoc "Retains a failed activation's partition and schedules up to eight retries with capped exponential backoff."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    tag = input.arguments.tag
    attempt = Map.get(state.child_attempts, tag, 0) + 1

    cond do
      state.status != :sorting || !Map.has_key?(state.partitions, tag) ||
        Map.has_key?(state.started_children, tag) || Map.has_key?(state.results, tag) ->
        Aikido.Types.ActionResult.new(state: state)

      attempt > 8 || !Aikido.Error.retryable?(input.arguments.reason) ->
        AgentExamples.Quicksort.PartitionTree.fail_partition(
          state,
          input.arguments,
          input.context.aikido
        )

      true ->
        state = %{state | child_attempts: Map.put(state.child_attempts, tag, attempt)}

        retry = %Aikido.Signal{
          type: "quicksort.retry_child",
          source: "/examples/quicksort",
          data: %{tag: tag, attempt: attempt}
        }

        Aikido.Types.ActionResult.new(
          state: state,
          directives: [
            %Aikido.Directives.Schedule{
              delay_ms: min(500 * Integer.pow(2, attempt - 1), 10_000),
              message: retry
            }
          ]
        )
    end
  end
end
