defmodule Aikido.Slices.AiReact.Signals.Handoff do
  @moduledoc "Typed payload for `ai.react.handoff`."
  use Aikido.Signal

  signal do
    type "ai.react.handoff"

    schema do
      attribute :messages, {:array, :term} do
        description "Native conversation messages replacing the slice context while it is idle."
        allow_nil? false
      end
    end
  end
end
