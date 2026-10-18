defmodule AgentExamples.AI.Tools do
  @moduledoc "Native Ash actions exposed to the model as tools."
  use Ash.Resource, domain: AgentExamples.Agents, data_layer: Ash.DataLayer.Simple

  def for_assistant(label \\ "runtime") do
    build_ash_ai_tools([:text_stats, :stamp], %{stamp_label: label})
  end

  def for_team(label \\ "team") do
    for_assistant(label) ++
      [{__MODULE__, :team_roster}, {__MODULE__, :spawn_worker}, {__MODULE__, :delegate}]
  end

  @doc "Build real Ash AI callbacks at runtime, including AshLua eval/docs tools."
  def from_ash_ai do
    build_ash_ai_tools([:ash_text_stats, :run_lua, :lua_docs])
  end

  defp build_ash_ai_tools(names, runtime_context \\ %{}) do
    {tools, registry} =
      AshAi.build_tools_and_registry(
        otp_app: :agent_examples,
        tools: names
      )

    Enum.map(tools, fn tool ->
      callback = Map.fetch!(registry, tool.name)

      {tool,
       fn arguments, context ->
         context =
           Map.update(context, :context, runtime_context, &Map.merge(&1 || %{}, runtime_context))

         callback.(arguments, context)
       end}
    end)
  end

  actions do
    action :stamp, :map do
      description "Attach this caller's runtime label to the supplied text."
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        {:ok,
         %{label: Map.get(input.context, :stamp_label, "runtime"), text: input.arguments.text}}
      end
    end

    action :text_stats, :map do
      description "Count the words and characters in the supplied text."
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        text = input.arguments.text
        {:ok, %{words: length(String.split(text)), characters: String.length(text)}}
      end
    end

    action :team_roster, :map do
      description "List this agent's running teammates. Available only inside a team."

      run fn input, context ->
        with {:ok, team, _member, _caller} <- scope(input, context) do
          members = team.team.members |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

          templates =
            team.__struct__.__aikido_team_config__().workers
            |> Map.keys()
            |> Enum.map(&to_string/1)
            |> Enum.sort()

          {:ok, %{members: members, templates: templates}}
        end
      end
    end

    action :spawn_worker, :map do
      description "Start an agent or team from a template in your nearest team. Inherits your tools and model, and records you as owner. Use team_roster or agents.members to list templates."
      argument :name, :string, allow_nil?: false
      argument :specialty, :string, default: "text analysis"
      argument :template, :string, default: "researcher"

      run fn input, context ->
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
    end

    action :delegate, :map do
      description "Assign a bounded task to a running worker and wait for its answer. Cannot target yourself or the orchestrator."
      argument :member, :string, allow_nil?: false
      argument :text, :string, allow_nil?: false

      run fn input, context ->
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
    end

    action :stop_worker, :map do
      description "Stop one of your owned workers or teams and its descendants. Keeps its desired topology entry."
      argument :member, :string, allow_nil?: false
      run fn input, context -> manage(input, context, :stop_member) end
    end

    action :remove_worker, :map do
      description "Remove one of your owned workers or teams and its descendants from the topology."
      argument :member, :string, allow_nil?: false
      run fn input, context -> manage(input, context, :remove_member) end
    end
  end

  defp initial_state(caller, resource, specialty) do
    caller
    |> Map.take([:tools, :tool_context, :model, :client, :max_iterations, :llm_opts])
    |> Map.put(:specialty, specialty)
    |> Map.filter(fn {name, _} -> Ash.Resource.Info.attribute(resource, name) end)
  end

  defp resolve_template(team, name) do
    case Enum.find(team.__struct__.__aikido_team_config__().workers, fn {key, _} ->
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
         status: if(action == :stop_member, do: "stopped", else: "removed")
       }}
    end
  end

  defp resolve_topology_member(team, name) do
    case Enum.find(Map.keys(team.team.topology.nodes), &(to_string(&1) == name)) do
      nil -> {:error, "Worker is not in this team's topology"}
      key -> {:ok, key}
    end
  end

  defp owned_by?(_nodes, _member, nil), do: true
  defp owned_by?(_nodes, member, member), do: false

  defp owned_by?(nodes, member, caller) do
    case nodes[member].owner do
      ^caller -> true
      nil -> false
      parent -> owned_by?(nodes, parent, caller)
    end
  end

  defp resolve_member(team, name) do
    # Match existing keys without turning model input into new atoms.
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
        function_exported?(resource, :__aikido_team_config__, 0) ->
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
