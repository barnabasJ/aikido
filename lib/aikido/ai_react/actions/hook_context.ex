defmodule Aikido.AiReact.Actions.HookContext do
  @moduledoc "Queues hook context for the matching active run’s next model request."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Hooks}

  @impl true
  def run(input, _opts, _context) do
    input.arguments.state
    |> queue_context_for_matching_run(Map.delete(input.arguments, :state))
  end

  @doc false
  def queue_context_for_matching_run(state, data) do
    state =
      if state.request_id == data.request_id && state.status in [:setup, :running],
        do:
          Hooks.queue_hook_text_for_next_model_request(state, data[:name] || "async", data.text),
        else: state

    Aikido.Types.ActionResult.new(state: state)
  end
end
