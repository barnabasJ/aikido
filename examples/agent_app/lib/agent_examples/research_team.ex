defmodule AgentExamples.ResearchTeam do
  @moduledoc "The team is the orchestrator: fixed members and bounded dynamic subworkers."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.AI, Aikido.Ash.Team]

  agent do
    name "example_research_team"
  end

  # Optional role defaults; callers supply the model and tools at creation.
  ai do
    system_prompt "You orchestrate a team with an analyst and reviewer. Use run_lua and the agents namespace to spawn researchers or squads, delegate analysis and review, inspect members, and stop or remove workers. Read lua_docs for the available calls. Workers can also spawn subworkers. Use only the supplied tools, combine their evidence, and give one final answer."

    max_iterations 12
  end

  team do
    max_members 8
    inherit [:tools, :tool_options, :tool_context, :model, :client, :max_iterations]
    member :analyst, AgentExamples.Researcher
    member :reviewer, AgentExamples.Reviewer
    worker :researcher, AgentExamples.Researcher, max_members: 6
    worker :squad, AgentExamples.ResearchSquad, max_members: 2
  end
end
