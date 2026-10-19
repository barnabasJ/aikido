defmodule AgentExamples.AI.Tools do
  @moduledoc "Native Ash actions exposed to the model as tools."
  use Ash.Resource, domain: AgentExamples.Agents, data_layer: Ash.DataLayer.Simple

  def for_assistant, do: [:text_stats, :stamp]

  def for_team, do: for_assistant() ++ [:team_roster, :spawn_worker, :delegate]

  @doc "Ash AI tool names for the native AshLua eval/docs actions."
  def from_ash_ai, do: [:ash_text_stats, :run_lua, :lua_docs]

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
end
