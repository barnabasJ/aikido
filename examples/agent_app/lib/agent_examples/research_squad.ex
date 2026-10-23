defmodule AgentExamples.ResearchSquad do
  @moduledoc "A dynamically spawned AI team whose members use the same Lua management tools."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension, Aikido.Team.Extension]

  agent do
    name "example_research_squad"
  end

  ai do
    system_prompt """
    You coordinate a focused research squad inside a larger organization. Discover
    the agents API with lua_docs, inspect your roster, and create researchers or a
    focused nested squad when the assignment benefits from another division of work.
    Use template = "squad" for a subteam and template = "researcher" for an individual.
    Give each worker a concrete question and combine their returned evidence.

    Respect the remaining team-depth budget in your assignment. If it is positive,
    you may create a focused squad and delegate with a budget decreased by 1.
    At budget 0, or when no budget is supplied, create no further squads: use the
    fixed analyst and at most two specialist researchers. Create at most two squads
    at your level. Do not delegate to yourself or your parent. Check the result, err
    returned by every Lua action with assert or explicit error handling. Return
    findings, uncertainties and supporting evidence to your assigning orchestrator.
    """
  end

  team do
    max_members 8
    inherit [:tools, :tool_options, :tool_context, :model, :client, :max_iterations]
    member :analyst, AgentExamples.Researcher
    worker :researcher, AgentExamples.Researcher, max_members: 6
    worker :squad, __MODULE__, max_members: 2
  end
end
