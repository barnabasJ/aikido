defmodule Aikido.Ash.Team.Actions.TaskCompleted do
  @moduledoc "Accepts a completed task result only from its current member incarnation and builds notifications."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Ash.Team.{Inputs, Tasks}

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(reduce(signal, state, context, config))
  end

  defp reduce(signal, state, context, _config) do
    data = signal.data

    case Map.get(state.tasks, data.task_id) do
      %{status: :dispatched, attempt: attempt, member: member} = task
      when attempt == data.attempt and member == data.member ->
        task = %{
          task
          | status: :completed,
            result: Map.get(data, :result, Map.get(data, :reason))
        }

        state = put_in(state.tasks[data.task_id], task)
        {:ok, state, Tasks.notify(task, state, context)}

      _ ->
        {:ok, state, []}
    end
  end
end
