defmodule Aikido.AiReact.Signals.ReplaceContext do
  @moduledoc "Installs caller-supplied conversation history while idle and refreshes the cached token estimate."
  use Aikido.Signal

  signal do
    type "ai.react.replace_context"

    description "Installs caller-supplied conversation history while idle and refreshes the cached token estimate."

    schema do
      attribute :messages, {:array, :term} do
        description "Caller-supplied conversation history to install while the slice is idle."
        allow_nil? false
      end
    end
  end
end
