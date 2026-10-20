defmodule Aikido.Signals.AiReact.ToolsReady do
  @moduledoc "Typed payload for `ai.react.tools.ready`."
  use Aikido.Signal

  signal do
    type "ai.react.tools.ready"

    schema do
      attribute :request_id, :string, allow_nil?: false

      attribute :prepared_tools, :term, allow_nil?: false
    end
  end
end
