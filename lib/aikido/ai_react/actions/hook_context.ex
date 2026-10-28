defmodule Aikido.AiReact.Actions.HookContext do
  @moduledoc "Queues hook context for the matching active run’s next model request."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.HookQueue

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- process_hook_context(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, [:hook_context])

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp process_hook_context(input) do
    input.arguments.state
    |> queue_context_for_matching_run(Map.delete(input.arguments, :state))
  end

  @doc false
  def queue_context_for_matching_run(state, data) do
    state =
      if state.request_id == data.request_id && state.status in [:setup, :running],
        do:
          HookQueue.queue_hook_text_for_next_model_request(
            state,
            data[:name] || "async",
            data.text
          ),
        else: state

    {:ok, state, []}
  end
end
