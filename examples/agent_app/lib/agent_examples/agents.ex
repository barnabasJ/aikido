defmodule AgentExamples.Agents do
  @moduledoc "The public interface to all example agents."
  use Ash.Domain,
    otp_app: :agent_examples,
    extensions: [Aikido.Domain.Extension, AshAi, AshLua.Domain]

  resources do
    resource AgentExamples.LuaAssistant.Tools
    resource AgentExamples.AdaptiveAssistant.ToolPreparation
    resource AgentExamples.VerifiedAssistant.Verification
    resource AgentExamples.ResilientAssistant.Failures
    resource AgentExamples.AI.Tools
    resource AgentExamples.AI.LuaSurface
  end

  lua do
    namespace "session" do
      action :whoami, AgentExamples.LuaAssistant.Tools, :whoami
    end

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
    tool :scoped_lua, AgentExamples.LuaAssistant.Tools, :eval
    tool :scoped_lua_docs, AgentExamples.LuaAssistant.Tools, :docs
    tool :record_evidence, AgentExamples.VerifiedAssistant.Verification, :record_evidence
    tool :fail_example, AgentExamples.ResilientAssistant.Failures, :fail
    tool :team_roster, AgentExamples.AI.Tools, :team_roster
    tool :spawn_worker, AgentExamples.AI.Tools, :spawn_worker
    tool :delegate, AgentExamples.AI.Tools, :delegate
    tool :stop_worker, AgentExamples.AI.Tools, :stop_worker
    tool :remove_worker, AgentExamples.AI.Tools, :remove_worker
    tool :text_stats, AgentExamples.AI.Tools, :text_stats
    tool :stamp, AgentExamples.AI.Tools, :stamp

    tool :run_lua, AgentExamples.AI.LuaSurface, :eval do
      description """
      Execute Lua against the exposed Ash actions. Calls return result, err; a failure
      returns nil, err rather than raising. Use return assert(agents.members({})) to
      inspect teammates, or return assert(agents.delegate({input = {member = "analyst",
      text = "Review the evidence"}})) to delegate. Check errors or use assert; pcall
      alone does not detect returned errors. Read lua_docs for available functions.
      """
    end

    tool :lua_docs, AgentExamples.AI.LuaSurface, :docs do
      description """
      Discover the exposed Lua API. Pass input = {} for the callable/topic index,
      input = {name = "full"} for full documentation, or an exact indexed name such
      as agents.spawn, agents.delegate, agents.members, transactions or error-handling.
      Bare namespaces such as agents are not callable names. Search accepts a short
      term such as spawn; use a returned exact name to fetch its contract.
      """
    end
  end

  agents do
    agent :lua_assistant, AgentExamples.LuaAssistant
    agent :adaptive, AgentExamples.AdaptiveAssistant
    agent :verified, AgentExamples.VerifiedAssistant
    agent :resilient, AgentExamples.ResilientAssistant
    agent :recoverable, AgentExamples.RecoverableAssistant
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
