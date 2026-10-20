defmodule Aikido.Signals.AiReact.Message do
  @moduledoc "Typed payload for `ai.react.message`."
  use Aikido.Signal

  signal do
    type "ai.react.message"

    schema do
      attribute :text, :string, allow_nil?: false
    end
  end
end
