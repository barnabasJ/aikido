defmodule AgentExamples.VerifiedTeam.Commands.CompleteEvidence do
  @moduledoc "Checks the authoritative native assignment record before reporting Todo completion evidence."
  use Ash.Resource.Actions.Implementation
  alias AgentExamples.AI.Tools.TeamAccess

  @impl true
  def run(input, _opts, context) do
    id = input.arguments.task_id
    options = Ash.Scope.to_opts(context, context: input.context)

    with {:ok, team, nil, _record} <- TeamAccess.resolve_caller_team(input, context),
         %{status: :completed, member: :evidence, result: result, metadata: %{required_todo: ^id}} <-
           team.team.tasks[id],
         true <- is_binary(result) && String.trim(result) != "" do
      evidence = %{task_id: id, member: :evidence, result: result}

      AgentExamples.VerifiedTeam
      |> Ash.ActionInput.for_action(
        :todo_complete,
        %{agent: team, id: id, result: evidence},
        options
      )
      |> Ash.run_action(options)
      |> case do
        {:ok, _} -> {:ok, %{evidence: evidence}}
        error -> error
      end
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         Ash.Error.Action.InvalidArgument.exception(
           field: :task_id,
           message:
             "No completed required evidence assignment matches this task_id. Wait for its result, inspect the task, or request a new check after a failure."
         )}
    end
  end
end
