defmodule Aikido.Signals.AiReact.Deliver do
  @moduledoc "Typed payload for `ai.react.deliver`."
  use Aikido.Signal

  signal do
    type "ai.react.deliver"

    schema do
      attribute :metadata, :map, default: %{}

      attribute :text, :string, allow_nil?: false

      attribute :request_id, :string, allow_nil?: false
    end
  end
end
