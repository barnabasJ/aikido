defmodule Aikido.AiWorker.Actions.Cancel do
  @moduledoc """
  Pure reducer that removes `task_id` from the worker queue.

  When that task is active, clears its pending record and returns an `Emit`
  directive cancelling the matching AI request on the owning agent.
  """
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    with {:ok, state, directives} <- cancel_team_task(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, [:queue, :pending])

      Aikido.Types.ActionResult.new(changes: changes, directives: directives)
    end
  end

  defp cancel_team_task(input) do
    state = input.arguments.state
    id = input.arguments.task_id
    state = Map.put(state, :queue, Enum.reject(Map.get(state, :queue, []), &(&1.task_id == id)))

    if state.pending && state.pending.task_id == id do
      signal =
        %Aikido.Signal{
          id: nil,
          type: "ai.react.cancel",
          data: %{request_id: id},
          source: "/aikido"
        }

      {:ok, %{state | pending: nil},
       [Aikido.Directives.emit_to_pid(signal, input.context.aikido.agent_pid)]}
    else
      {:ok, state, []}
    end
  end
end
