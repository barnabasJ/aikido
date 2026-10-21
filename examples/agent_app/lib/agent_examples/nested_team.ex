defmodule AgentExamples.NestedTeam do
  @moduledoc "An extensible mixed tree: agents can own agents or teams, and teams can nest recursively."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "example_nested_team"
  end

  team do
    member :lead, AgentExamples.Worker
    member :home, AgentExamples.Team
    worker :squad, AgentExamples.Team, max_members: 3
  end
end
