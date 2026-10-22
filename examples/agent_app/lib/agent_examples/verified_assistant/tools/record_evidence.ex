defmodule AgentExamples.VerifiedAssistant.Tools.RecordEvidence do
  @moduledoc "Tool I/O boundary sending evidence through the agent's public todo command."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    caller = input.context.aikido
    options = Ash.Scope.to_opts(context, context: input.context)

    caller.agent_resource
    |> Ash.ActionInput.for_action(
      :todo_complete,
      %{agent: caller.agent_id, id: input.arguments.id, result: "Checked by the evidence tool"},
      options
    )
    |> Ash.run_action(options)
    |> case do
      {:ok, _} -> {:ok, %{evidence: "Checked by the evidence tool"}}
      error -> error
    end
  end
end
