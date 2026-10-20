defmodule Aikido.Signals.AiReact.HandoffCompleted do
  @moduledoc "Typed payload for `ai.react.context_handoff.completed`."
  use Aikido.Signal

  signal do
    type "ai.react.context_handoff.completed"

    schema do
      attribute :request_id, :string do
        description "Run identifier used to correlate this event with the active request."
        allow_nil? false
      end

      attribute :handoff_id, :integer do
        description "Identifier correlating this result with the pending context handoff."
        allow_nil? false
      end

      attribute :turn, :term do
        description "Native ReqLLM response produced by the completed model request."
        allow_nil? false
      end

      attribute :iteration, :integer do
        description "Model turn number associated with this result."
      end
    end
  end
end
