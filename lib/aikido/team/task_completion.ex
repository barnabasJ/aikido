defmodule Aikido.Team.TaskCompletion do
  @moduledoc "Keeps a team's AI run open while its own background assignments still owe results."

  @doc "Hold a proposed answer until background tasks notifying this team have settled."
  def await_background_results(state, agent_state) do
    case Map.get(agent_state, :team) do
      nil ->
        state

      team ->
        assignments = Map.values(team.tasks) ++ Map.values(team.pending_tasks)

        if Enum.any?(assignments, &awaiting_result?/1),
          do: %{state | status: :waiting},
          else: state
    end
  end

  defp awaiting_result?(task) do
    Map.get(task, :status, :dispatched) == :dispatched && task[:mode] == :background &&
      task[:notify] == :self && task[:requester] in [nil, :self]
  end
end
