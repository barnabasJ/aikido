defmodule AgentExamples.AI.Tools.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, [action: :stamp], _context) do
    {:ok, %{label: Map.get(input.context, :stamp_label, "runtime"), text: input.arguments.text}}
  end

  @impl true
  def run(input, [action: :text_stats], _context) do
    text = input.arguments.text
    {:ok, %{words: length(String.split(text)), characters: String.length(text)}}
  end

  @impl true
  def run(input, [action: :team_roster], context) do
    with {:ok, team, _member, _caller} <- scope(input, context) do
      members = team.team.members |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

      templates =
        Aikido.Dsl.Agent.Info.team_config(team.__struct__).workers
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.sort()

      {:ok, %{members: members, templates: templates}}
    end
  end

  @impl true
  def run(input, [action: :spawn_worker], context) do
    with {:ok, team, owner, caller} <- scope(input, context),
         {:ok, template, resource} <- resolve_template(team, input.arguments.template),
         {:ok, _started} <-
           Aikido.Ash.command(
             team,
             %{
               member: input.arguments.name,
               template: template,
               owner: owner,
               initial_state: initial_state(caller, resource, input.arguments.specialty)
             },
             Ash.Scope.to_opts(context, context: input.context, action: :add_member)
           ) do
      {:ok, %{member: input.arguments.name, status: "started", owner: owner}}
    end
  end

  @impl true
  def run(input, [action: :delegate], context) do
    with {:ok, team, caller, _record} <- scope(input, context),
         {:ok, member} <- resolve_member(team, input.arguments.member),
         true <- member != caller || {:error, "Cannot delegate to yourself"},
         {:ok, result} <-
           AgentExamples.AI.delegate(team, member, input.arguments.text,
             ash: Ash.Scope.to_opts(context, context: input.context)
           ) do
      {:ok, %{member: input.arguments.member, result: result}}
    end
  end

  @impl true
  def run(input, [action: :stop_worker], context) do
    manage(input, context, :stop_member)
  end

  @impl true
  def run(input, [action: :remove_worker], context) do
    manage(input, context, :remove_member)
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
    case Enum.find(Aikido.Dsl.Agent.Info.team_config(team.__struct__).workers, fn {key, _} ->
           to_string(key) == name
         end) do
      {key, %{resource: resource}} -> {:ok, key, resource}
      nil -> {:error, "Unknown worker template in this team"}
    end
  end

  defp manage(input, context, action) do
    with {:ok, team, caller, _record} <- scope(input, context),
         {:ok, member} <- resolve_topology_member(team, input.arguments.member),
         true <-
           owned_by?(team.team.topology.nodes, member, caller) ||
             {:error, "You may only manage your own descendants"},
         {:ok, _} <-
           Aikido.Ash.command(
             team,
             %{member: member},
             Ash.Scope.to_opts(context, context: input.context, action: action)
           ) do
      {:ok,
       %{
         member: input.arguments.member,
         status:
           if action == :stop_member do
             "stopped"
           else
             "removed"
           end
       }}
    end
  end

  defp resolve_topology_member(team, name) do
    case Enum.find(Map.keys(team.team.topology.nodes), &(to_string(&1) == name)) do
      nil -> {:error, "Worker is not in this team's topology"}
      key -> {:ok, key}
    end
  end

  defp owned_by?(_nodes, _member, nil) do
    true
  end

  defp owned_by?(_nodes, member, member) do
    false
  end

  defp owned_by?(nodes, member, caller) do
    case nodes[member].owner do
      ^caller -> true
      nil -> false
      parent -> owned_by?(nodes, parent, caller)
    end
  end

  defp resolve_member(team, name) do
    case Enum.find(Map.keys(team.team.members), &(to_string(&1) == name)) do
      nil -> {:error, "Worker is not running"}
      key -> {:ok, key}
    end
  end

  defp scope(input, context) do
    caller = input.context[:aikido]
    resource = caller && caller[:agent_resource]
    opts = Ash.Scope.to_opts(context, context: input.context)

    with true <-
           (is_atom(resource) && not is_nil(resource)) ||
             {:error, "Agent management requires agent runtime context"},
         {:ok, record} <- Aikido.Ash.inspect(resource, caller.agent_id, opts) do
      cond do
        !is_nil(Aikido.Dsl.Agent.Info.team_config(resource)) ->
          {:ok, record, nil, record}

        caller.parent && caller.parent.meta[:team_resource] ->
          with {:ok, team} <-
                 Aikido.Ash.inspect(
                   caller.parent.meta.team_resource,
                   caller.parent.meta.team_id,
                   opts
                 ) do
            {:ok, team, caller.parent.meta.member, record}
          end

        true ->
          {:error, "This agent is not managed by a team"}
      end
    end
  end
end
