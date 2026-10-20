defmodule Aikido.Signals.AiReact.HandoffFailed do
  @moduledoc "Typed payload for `ai.react.context_handoff.failed`."
  use Aikido.Signal

  signal do
    type "ai.react.context_handoff.failed"

    schema do
      attribute :request_id, :string, allow_nil?: false

      attribute :handoff_id, :integer, allow_nil?: false

      attribute :reason, :term, allow_nil?: false
    end
  end
end
