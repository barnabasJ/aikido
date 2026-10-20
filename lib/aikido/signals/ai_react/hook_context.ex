defmodule Aikido.Signals.AiReact.HookContext do
  @moduledoc "Typed payload for `ai.react.hook.context`."
  use Aikido.Signal

  signal do
    type "ai.react.hook.context"

    schema do
      attribute :request_id, :string, allow_nil?: false

      attribute :text, :string, allow_nil?: false

      attribute :name, :string
    end
  end
end
