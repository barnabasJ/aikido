defmodule AgentExamples.Team do
  @moduledoc "Starts child agents and sends signals through the generated domain interface."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.Team]

  agent do
    name "example_team"
  end

  team do
    member :counter, AgentExamples.Counter, initial_state: %{count: 10}
    member :notebook, AgentExamples.Notebook
    member :worker, AgentExamples.Worker
  end
end
