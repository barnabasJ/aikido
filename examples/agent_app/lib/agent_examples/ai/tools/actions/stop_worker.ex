defmodule AgentExamples.AI.Tools.Actions.StopWorker do
  @moduledoc "Stops an owned descendant while retaining its desired topology entry."
  use Ash.Resource.Actions.Implementation
  alias AgentExamples.AI.Tools.Context

  @impl true
  def run(input, _opts, context) do
    ash_opts = Ash.Scope.to_opts(context, context: input.context)

    with {:ok, team, caller, _record} <- Context.scope(input, context),
         {:ok, member} <- Context.resolve_topology_member(team, input.arguments.member),
         true <-
           Context.owned_by?(team.team.topology.nodes, member, caller) ||
             {:error, "You may only manage your own descendants"},
         {:ok, _} <-
           team.__struct__
           |> Ash.ActionInput.for_action(
             :stop_member,
             %{agent: team.id, member: member},
             ash_opts
           )
           |> Ash.run_action(ash_opts) do
      {:ok, %{member: input.arguments.member, status: "stopped"}}
    end
  end
end
