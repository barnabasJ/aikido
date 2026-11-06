defmodule Aikido.AiReact.Signals.Message do
  @moduledoc "Typed payload for `ai.react.message`."
  use Aikido.Signal

  signal do
    type "ai.react.message"

    schema do
      attribute :content_parts, {:array, :struct} do
        description "Ordered native ReqLLM content parts appended after the authored text in one user message."
        sensitive? true
        constraints items: [instance_of: ReqLLM.Message.ContentPart]
        default []
        allow_nil? false
      end

      attribute :text, :string do
        description "User message to append immediately or queue at the next safe model boundary."
        allow_nil? false
        constraints trim?: false, allow_empty?: false
      end
    end
  end
end
