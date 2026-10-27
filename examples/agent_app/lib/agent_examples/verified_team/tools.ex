defmodule AgentExamples.VerifiedTeam.Tools do
  @moduledoc "Application evidence actions composed with native Team and Todo commands."
  use Ash.Resource, domain: AgentExamples.Agents

  actions do
    action :request_evidence, :map do
      description "Create a required evidence todo and assign its background check."
      run AgentExamples.VerifiedTeam.Commands.RequestEvidence
    end

    action :complete_evidence, :map do
      description "Complete the required todo only after its tracked worker result is available."
      argument :task_id, :string, allow_nil?: false
      run AgentExamples.VerifiedTeam.Commands.CompleteEvidence
    end
  end
end
