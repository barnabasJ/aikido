defmodule AgentExamples.ResearchSquad do
  @moduledoc "A dynamically spawned AI team whose members use the same Lua management tools."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.AI, Aikido.Ash.Team]

  agent do
    name "example_research_squad"
  end

  ai do
    system_prompt "Coordinate research through the supplied Lua tools. Spawn researchers in your own team when useful, delegate work, and combine their findings."
  end

  team do
    inherit [:tools, :tool_options, :tool_context, :model, :client, :max_iterations]
    member :analyst, AgentExamples.Researcher
    worker :researcher, AgentExamples.Researcher, max_members: 6
  end
end
