defmodule AgentExamples.Researcher do
  @moduledoc "An AI worker that can delegate to dynamically created workers of its own."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.AI]

  agent do
    name "example_researcher"

    schema do
      attribute :specialty, :string do
        description "Research specialty supplied to the assistant's role prompt."
        default "text analysis"
        public? true
      end
    end
  end

  ai do
    system_prompt "Complete your assigned task. Use your allowed tools to inspect evidence. You may spawn a specialist and delegate bounded sub-tasks when needed. Return a concise evidence-based result."

    max_iterations 8
  end
end
