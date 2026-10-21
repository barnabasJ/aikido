defmodule Aikido.AiReact.Actions.Cancel do
  @moduledoc "Fails a matching active run and clears its pending hooks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Completion, DirectivePlan}

  @impl true
  def run(input, _opts, _context) do
    input
    |> reduce()
    |> Completion.transition(
      input,
      :run_cancelled,
      Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason, :metadata])
    )
    |> DirectivePlan.prepare_tools_and_handoff(input)
  end

  defp reduce(input) do
    slice = input.arguments.state
    requested = Map.get(input.arguments, :request_id)

    if slice.status in [:setup, :running, :waiting] &&
         (is_nil(requested) || requested == slice.request_id) do
      Aikido.Types.ActionResult.new(
        state:
          slice
          |> Map.put(:status, :failed)
          |> Map.put(:error, :cancelled)
          |> Map.put(:hooks_pending, %{}),
        directives: []
      )
    else
      Aikido.Types.ActionResult.new(state: slice, directives: [])
    end
  end
end
