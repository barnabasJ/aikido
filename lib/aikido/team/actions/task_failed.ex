defmodule Aikido.Team.Actions.TaskFailed do
  @moduledoc "Accepts a failed task result only from its current member incarnation and builds notifications."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Tasks}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(record_task_failure(signal, state, context, config))
  end

  defp record_task_failure(signal, state, context, _config) do
    data = signal.data

    case Map.get(state.tasks, data.task_id) do
      %{status: :dispatched, attempt: attempt, member: member} = task
      when attempt == data.attempt and member == data.member ->
        task = %{task | status: :failed, result: Map.get(data, :result, Map.get(data, :reason))}
        state = put_in(state.tasks[data.task_id], task)
        {:ok, state, Tasks.notification_directives(task, state, context)}

      _ ->
        {:ok, state, []}
    end
  end
end
