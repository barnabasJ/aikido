defmodule Aikido.AiReact.Actions.Cancel do
  @moduledoc "Fails a matching active run and clears its pending hooks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Completion}

  @impl true
  def run(input, _opts, _context) do
    input
    |> cancel_matching_run()
    |> Completion.settle_result(input)
    |> Aikido.AiReact.Hooks.queue_event_hooks_if_changed(
      input,
      :run_cancelled,
      Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason, :metadata])
    )
  end

  defp cancel_matching_run(input) do
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
