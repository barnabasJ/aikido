defmodule AgentExamples.ConversationAssistant do
  @moduledoc "Conversation history, streaming, compaction and optional todo completion in one agent."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent, Aikido.Ash.AI]

  agent do
    name "conversation_assistant"
    slice :todos, Aikido.Slices.Todo
  end

  ai do
    system_prompt "Use conversation history to answer the latest user message."

    options %{
      streaming: true,
      completion: :todos,
      context_max_tokens: 4_000,
      protect_recent_tokens: 1_000
    }
  end
end
