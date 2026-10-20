defmodule AgentExamples.Agents do
  @moduledoc "The public interface to all example agents."
  use Ash.Domain, otp_app: :agent_examples, extensions: [Aikido.Ash.Domain, AshAi, AshLua.Domain]

  resources do
    resource AgentExamples.AI.Tools
    resource AgentExamples.AI.LuaSurface
  end

  lua do
    namespace "analysis" do
      action :text_stats, AgentExamples.AI.Tools, :text_stats, labels: [:analysis]
    end

    namespace "agents" do
      action :spawn, AgentExamples.AI.Tools, :spawn_worker, labels: [:agents]
      action :members, AgentExamples.AI.Tools, :team_roster, labels: [:agents]
      action :delegate, AgentExamples.AI.Tools, :delegate, labels: [:agents]
      action :stop, AgentExamples.AI.Tools, :stop_worker, labels: [:agents]
      action :remove, AgentExamples.AI.Tools, :remove_worker, labels: [:agents]
    end
  end

  tools do
    tool :team_roster, AgentExamples.AI.Tools, :team_roster
    tool :spawn_worker, AgentExamples.AI.Tools, :spawn_worker
    tool :delegate, AgentExamples.AI.Tools, :delegate
    tool :stop_worker, AgentExamples.AI.Tools, :stop_worker
    tool :remove_worker, AgentExamples.AI.Tools, :remove_worker
    tool :text_stats, AgentExamples.AI.Tools, :text_stats
    tool :stamp, AgentExamples.AI.Tools, :stamp
    tool :run_lua, AgentExamples.AI.LuaSurface, :eval
    tool :lua_docs, AgentExamples.AI.LuaSurface, :docs
  end

  agents do
    agent :conversation, AgentExamples.ConversationAssistant
    agent :assistant, AgentExamples.Assistant
    agent :hooked_assistant, AgentExamples.HookedAssistant
    agent :interactive_assistant, AgentExamples.InteractiveAssistant
    agent :researcher, AgentExamples.Researcher
    agent :reviewer, AgentExamples.Reviewer
    agent :research_team, AgentExamples.ResearchTeam
    agent :research_squad, AgentExamples.ResearchSquad
    agent :counter, AgentExamples.Counter
    agent :checklist, AgentExamples.Checklist
    agent :notebook, AgentExamples.Notebook
    agent :worker, AgentExamples.Worker
    agent :team, AgentExamples.Team
    agent :nested_team, AgentExamples.NestedTeam
  end
end
