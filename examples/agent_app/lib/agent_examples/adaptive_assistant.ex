defmodule AgentExamples.AdaptiveAssistant do
  @moduledoc "Isolated adaptive assistant scenario using native Ash commands and real directives."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "adaptive_assistant"
    persistence :temporary
  end

  ai do
    system_prompt "Use the supplied tools and report their evidence."
    max_iterations 12
    options %{tool_preparation: {AgentExamples.AdaptiveAssistant.ToolPreparation, :prepare}}
  end
end
