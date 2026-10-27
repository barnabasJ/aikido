defmodule AgentExamples.VerifiedTeam.EvidenceWorker do
  @moduledoc "Checks a focused assignment and returns evidence to its coordinating team."
  require AgentExamples.VerifiedTeam.EvidenceClient

  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "team_evidence_worker"
    persistence :temporary
  end

  ai do
    client AgentExamples.VerifiedTeam.EvidenceClient
    system_prompt "Perform the requested evidence check. Return concrete findings and explicitly state any limitations."
  end
end
