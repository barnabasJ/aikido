defmodule Aikido.Signals.AiReact.ToolResult do
  @moduledoc "Typed payload for `ai.react.tool.completed`."
  use Aikido.Signal

  signal do
    type "ai.react.tool.completed"

    schema do
      attribute :tool_call_id, :string, allow_nil?: false

      attribute :name, :string, allow_nil?: false

      attribute :content, :term, allow_nil?: true

      attribute :request_id, :string, allow_nil?: false
    end
  end
end
