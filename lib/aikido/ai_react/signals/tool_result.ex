defmodule Aikido.AiReact.Signals.ToolResult do
  @moduledoc "Typed payload for `ai.react.tool.completed`."
  use Aikido.Signal

  signal do
    type "ai.react.tool.completed"

    schema do
      attribute :tool_call_id, :string do
        description "Identifier correlating this result with one pending model-issued tool call."
        allow_nil? false
      end

      attribute :name, :string do
        description "Exposed tool name associated with this result."
        allow_nil? false
      end

      attribute :content, :term do
        description "Native tool output retained in the conversation, including an explicit nil result."
        allow_nil? true
      end

      attribute :request_id, :string do
        description "Run identifier used to correlate this event with the active request."
        allow_nil? false
      end
    end
  end
end
