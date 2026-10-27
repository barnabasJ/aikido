defmodule AgentExamples.VerifiedTeam.Commands.RequestEvidence do
  @moduledoc "Tool I/O boundary creating required work before dispatching its correlated assignment."
  use Ash.Resource.Actions.Implementation
  alias AgentExamples.AI.Tools.TeamAccess

  @impl true
  def run(input, _opts, context) do
    options = Ash.Scope.to_opts(context, context: input.context)
    id = Ash.UUIDv7.generate()

    with {:ok, team, nil, _record} <- TeamAccess.resolve_caller_team(input, context),
         {:ok, _} <- command(team, :todo_add, %{id: id, text: "Check correlated background result delivery", blocking?: true}, options) do
      assign_or_block_requirement(team, id, input.context.aikido.deadline_at, options)
    end
  end

  defp assign_or_block_requirement(team, id, deadline, options) do
    remaining = deadline - System.system_time(:millisecond)

    if remaining > 0 do
      dispatch_evidence(team, id, deadline, remaining, options)
    else
      command(team, :todo_block, %{id: id, reason: "The assignment deadline expired."}, options)
      {:error, Ash.Error.Action.InvalidArgument.exception(field: :task_id,
                 message: "The run deadline expired before evidence work could start. Start a new run before assigning it again.")}
    end
  end

  defp dispatch_evidence(team, id, deadline, remaining, options) do
    payload = %{member: :evidence, task_id: id, mode: :background, requester: :self,
                notify: :self, timeout_ms: remaining,
                payload: %{text: "Check how a background task result reaches its lead."},
                metadata: %{aikido_deadline_at: deadline, required_todo: id}}

    case command(team, :assign_task, payload, options) do
      {:ok, _} -> {:ok, %{task_id: id, member: "evidence"}}
      {:error, reason} ->
        command(team, :todo_block, %{id: id, reason: "Evidence assignment could not be dispatched."}, options)
        {:error, reason}
    end
  end

  defp command(team, action, arguments, options) do
    AgentExamples.VerifiedTeam
    |> Ash.ActionInput.for_action(action, Map.put(arguments, :agent, team), options)
    |> Ash.run_action(options)
  end
end
