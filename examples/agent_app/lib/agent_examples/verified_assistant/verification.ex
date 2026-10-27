defmodule AgentExamples.VerifiedAssistant.Verification do
  @moduledoc "Application-owned verification and evidence tools, executed under the caller scope."
  use Ash.Resource, domain: AgentExamples.Agents

  actions do
    action :verify, :boolean do
      argument :answer, :term
      argument :todos, {:array, :term}
      argument :metadata, :map
      run AgentExamples.VerifiedAssistant.Tools.VerifyEvidence
    end

    action :record_evidence, :map do
      argument :id, :string, allow_nil?: false
      run AgentExamples.VerifiedAssistant.Tools.RecordEvidence
    end
  end
end
