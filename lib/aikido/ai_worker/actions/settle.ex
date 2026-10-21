defmodule Aikido.AiWorker.Actions.Settle do
  @moduledoc """
  Pure reducer that correlates an observation with the pending task's AI run.

  For a terminal result, clears pending state, increments the completion count and
  returns a reply directive to the assigning team. Starts the next queued task by
  directive when AI is available; unrelated results cannot complete a pending task.
  """
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
      result = if ai.status == :completed, do: ai.result, else: ai.error
      complete_task(state, pending, ai.status, result, context)
    else
      if is_nil(pending) && ai.status in [:completed, :failed, :idle],
        do: next(state, context, []),
        else: Aikido.Types.ActionResult.new(state: state)
    end
  end

  @doc false
  def complete_task(state, task, status, result, context) do
    type =
      if status == :completed,
        do: "aikido.ash.team.task.completed",
        else: "aikido.ash.team.task.failed"

    reply =
      %Aikido.Signal{
        id: nil,
        type: type,
        data: Map.merge(Map.take(task, [:task_id, :member, :attempt]), %{result: result}),
        source: "/aikido"
      }
      |> Aikido.Signal.put_ctx(Map.get(task, :signal_context, %{}))

    next(%{state | pending: nil, completed: state.completed + 1}, context, [
      Aikido.Directives.emit_to_pid(reply, task.reply_to)
    ])
  end

  defp next(state, context, effects) do
    case Map.get(state, :queue, []) do
      [data | rest] ->
        {:ok, result} =
          Aikido.AiWorker.Actions.Accept.start_task(%{state | queue: rest}, data, context)

        Aikido.Types.ActionResult.new(
          state: result.state,
          directives: effects ++ result.directives
        )

      [] ->
        Aikido.Types.ActionResult.new(state: state, directives: effects)
    end
  end
end
