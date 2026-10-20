defmodule Aikido.Signals.AiReact.HandoffFailed do
  @moduledoc "Typed payload for `ai.react.context_handoff.failed`."
  use Aikido.Signal

  signal do
    type "ai.react.context_handoff.failed"

    schema do
      attribute :request_id, :string do
        description "Run identifier used to correlate this event with the active request."
        allow_nil? false
      end

      attribute :handoff_id, :integer do
        description "Identifier correlating this result with the pending context handoff."
        allow_nil? false
      end

      attribute :reason, :term do
        description "Failure reason reported by the supervised operation."
        allow_nil? false
      end
    end
  end
end
