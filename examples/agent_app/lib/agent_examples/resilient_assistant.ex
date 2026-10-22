defmodule AgentExamples.ResilientAssistant do
  @moduledoc "Isolated resilient assistant scenario using native Ash commands and real directives."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "resilient_assistant"
    persistence :temporary
  end

  ai do
    system_prompt "Use the supplied tools and report their evidence."
    max_iterations 12

    options %{
      model_timeout_ms: 3_000,
      model_max_retries: 1,
      retry_backoff_ms: 100,
      max_repeated_tool_cycles: 2,
      max_consecutive_tool_errors: 2
    }
  end
end
