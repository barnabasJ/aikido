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

      next(%{state | pending: nil, completed: state.completed + 1}, context, [
        Aikido.Directives.emit_to_pid(reply, pending.reply_to)
      ])
    else
      if is_nil(pending) && ai.status in [:completed, :failed, :idle],
        do: next(state, context, []),
        else: Aikido.ActionResult.new(state: state)
    end
  end

  defp next(state, context, effects) do
    case Map.get(state, :queue, []) do
      [data | rest] ->
        {:ok, result} =
          Aikido.Slices.AiWorker.Accept.start_task(%{state | queue: rest}, data, context)

        Aikido.ActionResult.new(state: result.state, directives: effects ++ result.directives)

      [] ->
        Aikido.ActionResult.new(state: state, directives: effects)
    end
  end
end
