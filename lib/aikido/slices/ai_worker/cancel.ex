defmodule Aikido.Slices.AiWorker.Cancel do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  def run(input, _, _) do
    state = input.arguments.state
    id = input.arguments.task_id
    state = Map.put(state, :queue, Enum.reject(Map.get(state, :queue, []), &(&1.task_id == id)))

    if state.pending && state.pending.task_id == id do
      signal = Jido.Signal.new!("ai.react.cancel", %{request_id: id})

      Aikido.ActionResult.new(
        state: %{state | pending: nil},
        directives: [Aikido.Directives.emit(signal)]
      )
    else
      Aikido.ActionResult.new(state: state)
    end
  end
end
