defmodule Aikido.Signals.AiReact.Failed do
  @moduledoc "Typed payload for `ai.react.failed`."
  use Aikido.Signal

  signal do
    type "ai.react.failed"

    schema do
      attribute :reason, :term, allow_nil?: false

      attribute :request_id, :string, allow_nil?: false
    end
  end
end
