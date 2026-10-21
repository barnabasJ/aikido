defmodule Aikido.AiReact.Actions.Failed do
  @moduledoc "Records a correlated execution failure unless the run is settled or handing off."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Completion}

  @impl true
  def run(input, _opts, _context) do
    if is_nil(Map.get(input.arguments.state, :hook_terminal)) do
      input
      |> record_execution_failure()
      |> Completion.apply_completion_requirements(input)
      |> Aikido.AiReact.Hooks.queue_event_hooks_if_changed(
        input,
        :run_failed,
        Map.take(input.arguments, [:query, :tool_call_id, :name, :content, :reason, :metadata])
      )
    else
      Aikido.Types.ActionResult.new(state: input.arguments.state)
    end
  end

  defp record_execution_failure(input) do
    reason = input.arguments[:reason]
    id = input.arguments[:request_id]
    slice = input.arguments.state

    cond do
      slice.request_id != id ->
        Aikido.Types.ActionResult.new(state: slice, directives: [])

      slice.status not in [:setup, :running] || not is_nil(Map.get(slice, :handoff_pending)) ->
        Aikido.Types.ActionResult.new(state: slice, directives: [])

      true ->
        Aikido.Types.ActionResult.new(
          state:
            slice
            |> Map.put(:status, :failed)
            |> Map.put(:error, reason)
            |> Map.put(:hooks_pending, %{}),
          directives: []
        )
    end
  end
end
