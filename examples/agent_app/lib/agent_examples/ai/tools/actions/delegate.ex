defmodule AgentExamples.AI.Tools.Actions.Delegate do
  @moduledoc "Delegates work to another running teammate through native scoped team actions."
  use Ash.Resource.Actions.Implementation
  alias AgentExamples.AI.Tools.TeamAccess

  @impl true
  def run(input, _opts, context) do
    with {:ok, team, caller, _record} <- TeamAccess.resolve_caller_team(input, context),
         {:ok, member} <- resolve_member(team, input.arguments.member),
         true <-
           member != caller ||
             {:error,
              AgentExamples.AI.Tools.ToolFailure.failure(
                "self_delegation",
                "You cannot delegate to yourself.",
                "Perform this task directly, or spawn a differently named researcher and delegate to it."
              )},
         {:ok, result} <-
           AgentExamples.AI.delegate(team, member, input.arguments.text,
             worker_lifecycle: input.arguments.worker_lifecycle,
             deadline_at: get_in(input.context, [:aikido, :deadline_at]),
             ash: Ash.Scope.to_opts(context, context: input.context)
           ) do
      {:ok, %{member: input.arguments.member, result: result}}
    else
      {:error, reason} ->
        {:error, AgentExamples.AI.Tools.ToolFailure.from_reason(reason)}
    end
  end

  defp resolve_member(team, name) do
    case Enum.find(Map.keys(team.team.members), &(to_string(&1) == name)) do
      nil -> {:error, "Worker is not running"}
      key -> {:ok, key}
    end
  end
end
