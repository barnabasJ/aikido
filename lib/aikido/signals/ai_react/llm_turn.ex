defmodule Aikido.Signals.AiReact.LlmTurn do
  @moduledoc "Typed payload for `ai.react.llm.completed`."
  use Aikido.Signal

  signal do
    type "ai.react.llm.completed"

    schema do
      attribute :iteration, :integer

      attribute :turn, :term, allow_nil?: false

      attribute :request_id, :string, allow_nil?: false
    end
  end
end
