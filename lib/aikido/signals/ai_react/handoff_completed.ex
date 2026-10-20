defmodule Aikido.Signals.AiReact.HandoffCompleted do
  @moduledoc "Typed payload for `ai.react.context_handoff.completed`."
  use Aikido.Signal

  signal do
    type "ai.react.context_handoff.completed"

    schema do
      attribute :request_id, :string, allow_nil?: false

      attribute :handoff_id, :integer, allow_nil?: false

      attribute :turn, :term, allow_nil?: false

      attribute :iteration, :integer
    end
  end
end
