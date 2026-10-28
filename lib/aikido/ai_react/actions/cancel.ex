defmodule Aikido.AiReact.Actions.Cancel do
  @moduledoc "Fails a matching active run and clears its pending hooks."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.RunState

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- cancel_requested_run(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp cancel_requested_run(input) do
    input
    |> cancel_matching_run()
    |> RunState.resolve_run_outcome(input)
    |> Aikido.AiReact.HookQueue.queue_event_hooks_if_changed(
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
      state =
        slice
        |> Map.put(:status, :failed)
        |> Map.put(:error, :cancelled)
        |> Map.put(:hooks_pending, %{})

      {:ok, state, []}
    else
      {:ok, slice, []}
    end
  end
end
