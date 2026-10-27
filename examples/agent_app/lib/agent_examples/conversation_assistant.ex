defmodule AgentExamples.ConversationAssistant do
  @moduledoc "Conversation history, streaming, model-written handoff and optional todo completion in one agent."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

  agent do
    name "conversation_assistant"
    slice :todos, Aikido.Todo.Slice
  end

  ai do
    system_prompt "Use conversation history to answer the latest user message."

    options %{
      streaming: true,
      completion: :todos,
      context_max_tokens: 4_000,
      handoff_buffer_tokens: 1_000
    }
  end
end
