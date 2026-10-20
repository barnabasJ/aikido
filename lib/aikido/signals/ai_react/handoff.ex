defmodule Aikido.Signals.AiReact.Handoff do
  @moduledoc "Typed payload for `ai.react.handoff`."
  use Aikido.Signal

  signal do
    type "ai.react.handoff"

    schema do
      attribute :messages, {:array, :term}, allow_nil?: false
    end
  end
end
