defmodule Aikido.AiReact.Actions.HookContext do
  @moduledoc "Queues hook context for the matching active run’s next model request."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{Hooks, DirectivePlan}

  @impl true
  def run(input, _opts, _context) do
    input.arguments.state
    |> reduce(Map.delete(input.arguments, :state))
    |> DirectivePlan.prepare_tools_and_handoff(input)
  end

  @doc false
  def reduce(state, data) do
    state =
      if state.request_id == data.request_id && state.status in [:setup, :running],
        do: Hooks.enqueue_context(state, data[:name] || "async", data.text),
        else: state

    Aikido.Types.ActionResult.new(state: state)
  end
end
