defmodule Aikido.AiReact.Signals.ModelAttempt do
  @moduledoc "Correlated model attempt diagnostics without request or response content."
  use Aikido.Signal

  signal do
    type "ai.react.model_attempt"

    schema do
      attribute :observation, Aikido.AiReact.Types.ModelAttempt do
        description "Safe incremental lifecycle facts for one model request attempt."
        allow_nil? false
      end
    end
  end
end
