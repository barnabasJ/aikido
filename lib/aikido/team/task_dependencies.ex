defmodule Aikido.Team.TaskDependencies do
  @moduledoc "Checks foreground task dependencies within a team's serialized task ledger."

  @doc "Reject a delegation when its target already depends on its requester."
  def validate_assignment(state, data) do
    requester = data[:requester]

    if data[:mode] == :foreground && not is_nil(requester) do
      tasks = Map.values(state.tasks) ++ Map.values(Map.get(state, :pending_tasks, %{}))

      edges =
        Enum.filter(
          tasks,
          &(Map.get(&1, :status, :dispatched) == :dispatched && &1[:mode] == :foreground)
        )

      case dependency_path(edges, data.member, requester, %{}) do
        nil ->
          :ok

        path ->
          {:error, Aikido.Team.Errors.DelegationCycle.exception(members: [requester | path])}
      end
    else
      :ok
    end
  end

  defp dependency_path(_edges, member, member, _visited), do: [member]

  defp dependency_path(edges, member, target, visited) do
    if Map.has_key?(visited, member) do
      nil
    else
      visited = Map.put(visited, member, true)

      edges
      |> Enum.filter(&(&1[:requester] == member))
      |> Enum.find_value(fn task ->
        case dependency_path(edges, task.member, target, visited) do
          nil -> nil
          path -> [member | path]
        end
      end)
    end
  end
end
