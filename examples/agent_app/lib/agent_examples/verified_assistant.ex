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
    system_prompt "Use the supplied tools and report their evidence."
    max_iterations 12

    options %{
      completion: :todos,
      todo_continuation: :continue,
      max_todo_continuations: 2,
      todo_verifier: {AgentExamples.VerifiedAssistant.Verification, :verify}
    }
  end
end
