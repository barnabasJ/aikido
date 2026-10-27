defmodule Aikido.AiReact.Signals.Failed do
  @moduledoc "Typed payload for `ai.react.failed`."
  use Aikido.Signal

  signal do
    type "ai.react.failed"

    schema do
      attribute :generation, :integer do
        description "Optional preparation generation; failures from superseded setups are ignored."
      end

      attribute :reason, :term do
        description "Failure reason reported by the supervised operation."
        allow_nil? false
      end

      attribute :request_id, :string do
        description "Run identifier used to correlate this event with the active request."
        allow_nil? false
      end
    end
  end
end
