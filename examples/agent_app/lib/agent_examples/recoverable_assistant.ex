defmodule AgentExamples.RecoverableAssistant do
  @moduledoc "Isolated permanent conversation recovery scenario using native Ash commands and real directives."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "recoverable_assistant"
    persistence :permanent
  end

  ai do
    system_prompt "Use the supplied tools and report their evidence."
    max_iterations 12
    options %{streaming: true}
  end
end
