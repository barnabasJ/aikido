defmodule Aikido.Slices.AiWorker.Settle do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    signal = input.context.aikido.signal
    state = input.arguments.state
    context = input.context.aikido
    ai = context.agent.state.ai
    pending = state.pending

    if pending && signal.data.task_id == pending.task_id && ai.request_id == pending.task_id &&
         ai.status in [:completed, :failed] do
      type =
        if ai.status == :completed do
          "aikido.ash.team.task.completed"
        else
          "aikido.ash.team.task.failed"
        end

      result =
        if ai.status == :completed do
          ai.result
        else
          ai.error
        end

      reply =
        Jido.Signal.new!(
          type,
          Map.merge(Map.take(pending, [:task_id, :member, :attempt]), %{result: result})
        )

      Aikido.ActionResult.new(
        state: %{state | pending: nil, completed: state.completed + 1},
        directives: [Aikido.Directives.emit_to_pid(reply, pending.reply_to)]
      )
    else
      Aikido.ActionResult.new(state: state, directives: [])
    end
  end
end
