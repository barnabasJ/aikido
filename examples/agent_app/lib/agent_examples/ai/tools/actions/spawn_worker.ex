defmodule AgentExamples.AI.Tools.Actions.SpawnWorker do
  @moduledoc "Starts an owned worker from a team template with the caller's model and tool configuration."
  use Ash.Resource.Actions.Implementation
  alias AgentExamples.AI.Tools.Context

  @impl true
  def run(input, _opts, context) do
    ash_opts = Ash.Scope.to_opts(context, context: input.context)

    with {:ok, team, owner, caller} <- Context.scope(input, context),
         {:ok, template, resource} <- resolve_template(team, input.arguments.template),
         {:ok, _started} <-
           team.__struct__
           |> Ash.ActionInput.for_action(
             :add_member,
             %{
               agent: team.id,
               member: input.arguments.name,
               template: template,
               owner: owner,
               initial_state: initial_state(caller, resource, input.arguments.specialty)
             },
             ash_opts
           )
           |> Ash.run_action(ash_opts) do
      {:ok, %{member: input.arguments.name, status: "started", owner: owner}}
    end
  end

  defp initial_state(caller, resource, specialty) do
    caller
    |> Map.take([
      :tools,
      :tool_options,
      :tool_context,
      :model,
      :client,
      :max_iterations,
      :llm_opts
    ])
    |> Map.put(:specialty, specialty)
    |> Map.filter(fn {name, _} -> Ash.Resource.Info.attribute(resource, name) end)
  end

  defp resolve_template(team, name) do
    case Enum.find(Aikido.Ash.Agent.Info.team_config(team.__struct__).workers, fn {key, _} ->
           to_string(key) == name
         end) do
      {key, %{resource: resource}} -> {:ok, key, resource}
      nil -> {:error, "Unknown worker template in this team"}
    end
  end
end
