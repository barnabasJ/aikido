defmodule Aikido.Team.Actions.BackgroundTask do
  @moduledoc "Releases a task's foreground wait and directs its eventual result to its requester."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    id = input.arguments.task_id

    case Map.fetch(state.tasks, id) do
      {:ok, %{status: :dispatched} = task} ->
        task =
          Map.merge(task, %{mode: :background, notify: task[:notify] || task[:requester] || :self})

        Aikido.Types.ActionResult.new(changes: %{tasks: Map.put(state.tasks, id, task)})

      {:ok, _settled} ->
        Aikido.Types.ActionResult.new(changes: nil)

      :error ->
        background_pending_assignment(state, id)
    end
  end

  defp background_pending_assignment(state, id) do
    case Map.fetch(Map.get(state, :pending_tasks, %{}), id) do
      {:ok, task} ->
        task =
          Map.merge(task, %{mode: :background, notify: task[:notify] || task[:requester] || :self})

        Aikido.Types.ActionResult.new(
          changes: %{pending_tasks: Map.put(state.pending_tasks, id, task)}
        )

      :error ->
        {:error,
         Ash.Error.Action.InvalidArgument.exception(
           field: :task_id,
           message:
             "Unknown delegated task #{id}. Inspect the team's tracked tasks before retrying."
         )}
    end
  end
end
