defmodule AgentExamples.Assistant do
  @moduledoc "A standalone assistant with the same start/ask/cancel interface as a team."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.AI]

  agent do
    name "example_assistant"
  end

  ai do
    system_prompt "Use text_stats to count the user's text, then report the result concisely."
    max_iterations 8
  end
end
