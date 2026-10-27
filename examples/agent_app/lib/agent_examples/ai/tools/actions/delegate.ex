defmodule AgentExamples.AI.Tools.Actions.Delegate do
  @moduledoc "Delegates work to another running teammate through native scoped team actions."
  use Ash.Resource.Actions.Implementation
  alias AgentExamples.AI.Tools.TeamAccess

  @impl true
  def run(input, _opts, context) do
    result =
      with {:ok, team, caller, _record} <- TeamAccess.resolve_caller_team(input, context) do
        delegate_or_background(input, context, team, caller)
      end

    case result do
      {:error, reason} -> {:error, AgentExamples.AI.Tools.ToolFailure.from_reason(reason)}
      result -> result
    end
  end

  defp delegate_or_background(
         %{arguments: %{task_id: id, mode: :background}} = input,
         context,
         team,
         caller
       )
       when not is_nil(id) do
    case team.team.tasks[id] || Map.get(team.team.pending_tasks, id) do
      %{requester: requester}
      when requester == caller or (is_nil(caller) and requester == :self) ->
        AgentExamples.AI.delegate(team, nil, nil,
          task_id: id,
          ash: Ash.Scope.to_opts(context, context: input.context)
        )

      _ ->
        {:error, "Only the requesting agent can background its tracked task. Check the task_id."}
    end
  end

  defp delegate_or_background(input, context, team, caller) do
    with true <-
           is_nil(input.arguments[:task_id]) ||
             {:error, "An existing task can only be moved to background mode."},
         true <-
           is_binary(input.arguments[:text]) || {:error, "Supply text when assigning a new task."},
         {:ok, member} <- resolve_member(team, input.arguments[:member]),
         true <-
           member != caller ||
             {:error,
              AgentExamples.AI.Tools.ToolFailure.failure(
                "self_delegation",
                "You cannot delegate to yourself.",
                "Perform this task directly, or spawn a differently named researcher and delegate to it."
              )},
         {:ok, result} <-
           AgentExamples.AI.delegate(team, member, input.arguments[:text],
             mode: input.arguments.mode,
             requester: caller || :self,
             worker_lifecycle: input.arguments.worker_lifecycle,
             deadline_at: get_in(input.context, [:aikido, :deadline_at]),
             ash: Ash.Scope.to_opts(context, context: input.context)
           ) do
      {:ok, %{member: input.arguments[:member], result: result}}
    else
      {:error, reason} ->
        {:error, AgentExamples.AI.Tools.ToolFailure.from_reason(reason)}
    end
  end

  defp resolve_member(team, name) do
    case Enum.find(Map.keys(team.team.members), &(to_string(&1) == name)) do
      nil ->
        {:error, "Worker is not running. Supply a running member name when assigning a new task."}

      key ->
        {:ok, key}
    end
  end
end
