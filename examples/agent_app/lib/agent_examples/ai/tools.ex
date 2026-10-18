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

  actions do
    action :stamp, :map do
      description "Attach this caller's runtime label to the supplied text."
      argument :text, :string, allow_nil?: false
      run {AgentExamples.AI.Tools.Implementation, action: :stamp}
    end

    action :text_stats, :map do
      description "Count the words and characters in the supplied text."
      argument :text, :string, allow_nil?: false
      run {AgentExamples.AI.Tools.Implementation, action: :text_stats}
    end

    action :team_roster, :map do
      description "List this agent's running teammates. Available only inside a team."
      run {AgentExamples.AI.Tools.Implementation, action: :team_roster}
    end

    action :spawn_worker, :map do
      description "Start an agent or team from a template in your nearest team. Inherits your tools and model, and records you as owner. Use team_roster or agents.members to list templates."

      argument :name, :string, allow_nil?: false
      argument :specialty, :string, default: "text analysis"
      argument :template, :string, default: "researcher"
      run {AgentExamples.AI.Tools.Implementation, action: :spawn_worker}
    end

    action :delegate, :map do
      description "Assign a bounded task to a running worker and wait for its answer. Cannot target yourself or the orchestrator."

      argument :member, :string, allow_nil?: false
      argument :text, :string, allow_nil?: false
      run {AgentExamples.AI.Tools.Implementation, action: :delegate}
    end

    action :stop_worker, :map do
      description "Stop one of your owned workers or teams and its descendants. Keeps its desired topology entry."

      argument :member, :string, allow_nil?: false
      run {AgentExamples.AI.Tools.Implementation, action: :stop_worker}
    end

    action :remove_worker, :map do
      description "Remove one of your owned workers or teams and its descendants from the topology."

      argument :member, :string, allow_nil?: false
      run {AgentExamples.AI.Tools.Implementation, action: :remove_worker}
    end
  end

  defp build_ash_ai_tools(names, runtime_context \\ %{}) do
    {tools, registry} = AshAi.build_tools_and_registry(otp_app: :agent_examples, tools: names)

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
end
