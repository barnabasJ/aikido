defmodule AgentExamples.VerifiedAssistant do
  @moduledoc "Isolated verified assistant scenario using native Ash commands and real directives."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "verified_assistant"
    persistence :temporary
    slice :todos, Aikido.Todo.Slice
  end

  ai do
    system_prompt "Complete the delivered work item by calling record_evidence with its ID, then report the evidence. A proposed answer is accepted only after the verifier confirms that the evidence tool recorded completion. Do not claim completion before using the tool."
    max_iterations 12

    options %{
      completion: :todos,
      todo_continuation: :nudge_once,
      max_todo_continuations: 2,
      todo_verifier: {AgentExamples.VerifiedAssistant.Verification, :verify}
    }
  end
end
