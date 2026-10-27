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
    system_prompt "This is a controlled loop-safety experiment. If the task is cycle, alternate text_stats and stamp with the text same input, one call per turn, and keep going until the runtime stops you. If it is errors, repeatedly call fail_example without changing the request. Otherwise use the available tools and follow the task. Retry and wait are deterministic offline scenarios; live requests use the real provider."
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
