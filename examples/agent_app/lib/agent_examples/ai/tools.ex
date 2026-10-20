defmodule AgentExamples.AI.Tools do
  @moduledoc "Native Ash actions exposed to the model as tools."
  use Ash.Resource, domain: AgentExamples.Agents, data_layer: Ash.DataLayer.Simple

  def for_assistant, do: [:text_stats, :stamp]

  def for_team, do: for_assistant() ++ [:team_roster, :spawn_worker, :delegate]

  @doc "Ash AI tool names for the native AshLua eval/docs actions."
  def for_lua, do: [:run_lua, :lua_docs]

  actions do
    action :stamp, :map do
      description "Attach this caller's runtime label to the supplied text."
      argument :text, :string, allow_nil?: false
      run AgentExamples.AI.Tools.Actions.Stamp
    end

    action :text_stats, :map do
      description "Count the words and characters in the supplied text."
      argument :text, :string, allow_nil?: false
      run AgentExamples.AI.Tools.Actions.TextStats
    end

    action :team_roster, :map do
      description "List this agent's running teammates. Available only inside a team."
      run AgentExamples.AI.Tools.Actions.TeamRoster
    end

    action :spawn_worker, :map do
      description "Start an agent or team from a template in your nearest team. Inherits your tools and model, and records you as owner. Use team_roster or agents.members to list templates."

      argument :name, :string, allow_nil?: false
      argument :specialty, :string, default: "text analysis"
      argument :template, :string, default: "researcher"
      run AgentExamples.AI.Tools.Actions.SpawnWorker
    end

    action :delegate, :map do
      description "Assign a bounded task to a running worker and wait for its answer. Cannot target yourself or the orchestrator."

      argument :member, :string, allow_nil?: false
      argument :text, :string, allow_nil?: false
      run AgentExamples.AI.Tools.Actions.Delegate
    end

    action :stop_worker, :map do
      description "Stop one of your owned workers or teams and its descendants. Keeps its desired topology entry."

      argument :member, :string, allow_nil?: false
      run AgentExamples.AI.Tools.Actions.StopWorker
    end

    action :remove_worker, :map do
      description "Remove one of your owned workers or teams and its descendants from the topology."

      argument :member, :string, allow_nil?: false
      run AgentExamples.AI.Tools.Actions.RemoveWorker
    end
  end
end
