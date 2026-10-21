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
    state = input.arguments.state
    context = input.context.aikido
    ai = context.agent.state.ai

    cond do
      pending_run_finished?(state.pending, context.signal.data, ai) ->
        result = if ai.status == :completed, do: ai.result, else: ai.error
        complete_task(state, state.pending, ai.status, result, context)

      is_nil(state.pending) && ai.status in [:completed, :failed, :idle] ->
        start_next_queued_task(state, context, [])

      true ->
        Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp pending_run_finished?(nil, _data, _ai), do: false

  defp pending_run_finished?(pending, data, ai) do
    data.task_id == pending.task_id && ai.request_id == pending.task_id &&
      ai.status in [:completed, :failed]
  end

  @doc false
  def complete_task(state, task, status, result, context) do
    reply = task_result_signal(task, status, result)

    state
    |> Map.put(:pending, nil)
    |> Map.update!(:completed, &(&1 + 1))
    |> start_next_queued_task(context, [Aikido.Directives.emit_to_pid(reply, task.reply_to)])
  end

  defp task_result_signal(task, status, result) do
    type =
      if status == :completed,
        do: "aikido.ash.team.task.completed",
        else: "aikido.ash.team.task.failed"

    %Aikido.Signal{
      id: nil,
      type: type,
      data: Map.merge(Map.take(task, [:task_id, :member, :attempt]), %{result: result}),
      source: "/aikido"
    }
    |> Aikido.Signal.put_ctx(Map.get(task, :signal_context, %{}))
  end

  defp start_next_queued_task(state, context, effects) do
    case Map.get(state, :queue, []) do
      [data | rest] ->
        with {:ok, result} <-
               Aikido.AiWorker.Actions.Accept.start_task(%{state | queue: rest}, data, context) do
          Aikido.Types.ActionResult.new(
            state: result.state,
            directives: effects ++ result.directives
          )
        end

      [] ->
        Aikido.Types.ActionResult.new(state: state, directives: effects)
    end
  end
end
