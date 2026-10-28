defmodule Aikido.AiReact.Actions.Failed do
  @moduledoc "Records a correlated execution failure unless the run is settled or handing off."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.RunState

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- settle_execution_failure(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp settle_execution_failure(input) do
    if is_nil(Map.get(input.arguments.state, :hook_terminal)) do
      input
      |> record_execution_failure()
      |> RunState.resolve_run_outcome(input)
      |> Aikido.AiReact.HookQueue.queue_event_hooks_if_changed(
        input,
        :run_failed,
        Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason, :metadata])
      )
    else
      {:ok, input.arguments.state, []}
    end
  end

  defp record_execution_failure(input) do
    reason = input.arguments[:reason]
    id = input.arguments[:request_id]
    slice = input.arguments.state

    cond do
      slice.request_id != id ||
          (input.arguments[:generation] && input.arguments.generation != slice.tools_generation) ->
        {:ok, slice, []}

      slice.status not in [:setup, :running] || not is_nil(Map.get(slice, :handoff_pending)) ->
        {:ok, slice, []}

      true ->
        state =
          slice
          |> Map.put(:status, :failed)
          |> Map.put(:error, reason)
          |> Map.put(:hooks_pending, %{})

        {:ok, state, []}
    end
  end
end
