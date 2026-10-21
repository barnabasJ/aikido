defmodule AgentExamples.Reviewer do
  @moduledoc "A fixed AI reviewer with the same public interface as every AI resource."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "example_reviewer"
  end

  ai do
    system_prompt "Review the supplied findings. Use evidence and your allowed tools to check numerical claims; delegate only when needed. Return a concise assessment."

    max_iterations 8
  end
end
