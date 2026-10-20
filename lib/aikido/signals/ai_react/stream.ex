defmodule Aikido.Signals.AiReact.Stream do
  @moduledoc "Typed payload for `ai.react.stream`."
  use Aikido.Signal

  signal do
    type "ai.react.stream"

    schema do
      attribute :request_id, :string, allow_nil?: false

      attribute :iteration, :integer, allow_nil?: false

      attribute :attempt, :integer, default: 0

      attribute :text, :string, default: "", constraints: [allow_empty?: true, trim?: false]

      attribute :thinking, :string, default: "", constraints: [allow_empty?: true, trim?: false]
    end
  end
end
