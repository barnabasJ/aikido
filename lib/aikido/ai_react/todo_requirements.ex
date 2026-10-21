defmodule Aikido.AiReact.TodoRequirements do
  @moduledoc """
  Decides whether blocking todos permit a ReAct run to finish.

  This optional policy maps the current todo state to completed, waiting or
  failed run status. It neither executes todos nor clears run resources.
  """

  @doc "Resolve completed, waiting or failed status from the configured blocking todos."
  def resolve_run_status(state, agent_state) do
    options = Map.get(state, :options) || %Aikido.AiReact.Options{}

    if options.completion == :todos do
      case Map.get(agent_state, options.todo_path) do
        %{items: items} -> resolve_blocking_todos(state, Enum.filter(items, & &1.blocking?))
        _ -> Map.merge(state, %{status: :failed, error: :todo_slice_not_mounted})
      end
    else
      state
    end
  end

  defp resolve_blocking_todos(state, items) do
    cond do
      blocked = Enum.find(items, &(&1.status == :blocked)) ->
        Map.merge(state, %{
          status: :failed,
          error: {:todo_blocked, blocked.id, blocked.reason}
        })

      Enum.any?(items, &(&1.status != :completed)) ->
        Map.put(state, :status, :waiting)

      true ->
        Map.put(state, :status, :completed)
    end
  end
end
