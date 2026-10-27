defmodule Aikido.AiReact.Signals.Cancel do
  @moduledoc "Typed payload for `ai.react.cancel`."
  use Aikido.Signal

  signal do
    type "ai.react.cancel"

    schema do
      attribute :request_id, :string do
        description "Optional run identifier to cancel; nil selects the active run."
        default nil
      end
    end
  end
end
