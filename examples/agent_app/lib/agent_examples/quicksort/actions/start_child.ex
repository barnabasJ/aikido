defmodule AgentExamples.Quicksort.Actions.StartChild do
  @moduledoc "Sends the child's assigned partition after its AgentServer reports readiness."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    case if(state.status == :sorting,
           do: Map.fetch(state.partitions, input.arguments.tag),
           else: :error
         ) do
      {:ok, numbers} ->
        state = %{
          state
          | started_children: Map.put(state.started_children, input.arguments.tag, true)
        }

        signal = %Aikido.Signal{
          type: "quicksort.sort",
          source: "/examples/quicksort",
          data: %{numbers: numbers, topic: state.topic}
        }

        Aikido.Types.ActionResult.new(
          state: state,
          directives: [
            AgentExamples.Quicksort.Progress.notification(state.topic, %{
              branch: state.branch <> input.arguments.tag,
              id: input.arguments.child_id,
              status: :idle,
              count: length(numbers),
              pivot: nil
            }),
            %Aikido.Directives.Emit{target: input.arguments.pid, signal: signal}
          ]
        )

      :error ->
        Aikido.Types.ActionResult.new(
          state: state,
          directives: [%Aikido.Directives.StopChild{tag: input.arguments.tag}]
        )
    end
  end
end
