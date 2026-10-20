defmodule Aikido.Signals.AiReact.Cancel do
  @moduledoc "Typed payload for `ai.react.cancel`."
  use Aikido.Signal

  signal do
    type "ai.react.cancel"

    schema do
      attribute :request_id, :string, default: nil
    end
  end
end
