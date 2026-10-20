defmodule Aikido.Slices.AiWorker.Cancel do
  @moduledoc """
  Pure reducer that removes `task_id` from the worker queue.

  When that task is active, clears its pending record and returns an `Emit`
  directive cancelling the matching AI request on the owning agent.
  """
  use Ash.Resource.Actions.Implementation

  def run(input, _, _) do
    state = input.arguments.state
    id = input.arguments.task_id
    state = Map.put(state, :queue, Enum.reject(Map.get(state, :queue, []), &(&1.task_id == id)))

    if state.pending && state.pending.task_id == id do
      signal =
        %Jido.Signal{id: nil, type: "ai.react.cancel", data: %{request_id: id}, source: "/aikido"}

      Aikido.Types.ActionResult.new(
        state: %{state | pending: nil},
        directives: [Aikido.Directives.emit_to_pid(signal, input.context.aikido.agent_pid)]
      )
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end
end
