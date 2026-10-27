defmodule AgentExamples.VerifiedTeam do
  @moduledoc "Tracks required background evidence with native Team and Todo slices."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension, Aikido.Team.Extension]

  agent do
    name "verified_team"
    persistence :temporary
    slice :todos, Aikido.Todo.Slice
  end

  ai do
    system_prompt "Call request_team_evidence to create a required work item and dispatch its background check. You may give an interim answer while it runs. After its result arrives, call complete_team_evidence with its task_id; that action checks the native task record before completing the todo. Incorporate the checked evidence into your final answer."
    options %{completion: :todos, todo_continuation: :wait}
  end

  team do
    inherit [:model, :client, :llm_opts, :tool_options]
    member :evidence, AgentExamples.VerifiedTeam.EvidenceWorker
  end
end
