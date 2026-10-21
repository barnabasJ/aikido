defmodule Aikido.AiReact.Signals.Stream do
  @moduledoc "Typed payload for `ai.react.stream`."
  use Aikido.Signal

  signal do
    type "ai.react.stream"

    schema do
      attribute :request_id, :string do
        description "Run identifier used to correlate this event with the active request."
        allow_nil? false
      end

      attribute :iteration, :integer do
        description "Model iteration producing this streaming delta."
        allow_nil? false
      end

      attribute :attempt, :integer do
        description "Streaming retry attempt used to reject deltas from superseded attempts."
        default 0
      end

      attribute :text, :string do
        description "Incremental assistant text produced by this streaming model response."
        default ""
        constraints allow_empty?: true, trim?: false
      end

      attribute :thinking, :string do
        description "Incremental thinking text produced by this streaming model response."
        default ""
        constraints allow_empty?: true, trim?: false
      end
    end
  end
end
