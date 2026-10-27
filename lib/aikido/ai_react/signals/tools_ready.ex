defmodule Aikido.AiReact.Signals.ToolsReady do
  @moduledoc "Typed payload for `ai.react.tools.ready`."
  use Aikido.Signal

  signal do
    type "ai.react.tools.ready"

    schema do
      attribute :generation, :integer do
        description "Preparation generation correlated with the latest tool setup request."
        default 0
        allow_nil? false
      end

      attribute :request_id, :string do
        description "Run identifier used to correlate this event with the active request."
        allow_nil? false
      end

      attribute :prepared_tools, :term do
        description "Prepared native tool descriptions and callback registry for the requested run."
        allow_nil? false
      end
    end
  end
end
