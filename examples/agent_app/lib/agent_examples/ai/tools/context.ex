defmodule AgentExamples.AI.Tools.Context do
  @moduledoc false

  def resolve_topology_member(team, name) do
    case Enum.find(Map.keys(team.team.topology.nodes), &(to_string(&1) == name)) do
      nil -> {:error, "Worker is not in this team's topology"}
      key -> {:ok, key}
    end
  end

  def owned_by?(_nodes, _member, nil) do
    true
  end

  def owned_by?(_nodes, member, member) do
    false
  end

  def owned_by?(nodes, member, caller) do
    case nodes[member].owner do
      ^caller -> true
      nil -> false
      parent -> owned_by?(nodes, parent, caller)
    end
  end

  def resolve_caller_team(input, context) do
    caller = input.context[:aikido]
    resource = caller && caller[:agent_resource]
    opts = Ash.Scope.to_opts(context, context: input.context)

    with true <-
           (is_atom(resource) && not is_nil(resource)) ||
             {:error, "Agent management requires agent runtime context"},
         {:ok, record} <-
           resource
           |> Ash.ActionInput.for_action(:inspect, %{agent: caller.agent_id}, opts)
           |> Ash.run_action(opts) do
      cond do
        !is_nil(Aikido.Agent.Info.team_config(resource)) ->
          {:ok, record, nil, record}

        caller.parent && caller.parent.meta[:team_resource] ->
          with {:ok, team} <-
                 caller.parent.meta.team_resource
                 |> Ash.ActionInput.for_action(
                   :inspect,
                   %{agent: caller.parent.meta.team_id},
                   opts
                 )
                 |> Ash.run_action(opts) do
            {:ok, team, caller.parent.meta.member, record}
          end

        true ->
          {:error, "This agent is not managed by a team"}
      end
    end
  end
end
