defmodule Aikido.AiReact.Signals.LlmTurn do
  @moduledoc "Typed payload for `ai.react.llm.completed`."
  use Aikido.Signal

  signal do
    type "ai.react.llm.completed"

    schema do
      attribute :iteration, :integer do
        description "Model turn number associated with this result."
      end

      attribute :turn, :term do
        description "Native ReqLLM response produced by the completed model request."
        allow_nil? false
      end

      attribute :request_id, :string do
        description "Run identifier used to correlate this event with the active request."
        allow_nil? false
      end
    end
  end
end
