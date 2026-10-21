defmodule Aikido.AiReact.Signals.Message do
  @moduledoc "Typed payload for `ai.react.message`."
  use Aikido.Signal

  signal do
    type "ai.react.message"

    schema do
      attribute :text, :string do
        description "User message to append immediately or queue at the next safe model boundary."
        allow_nil? false
      end
    end
  end
end
