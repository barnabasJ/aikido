defmodule Aikido.Slices.AiReact.Signals.HookContext do
  @moduledoc "Typed payload for `ai.react.hook.context`."
  use Aikido.Signal

  signal do
    type "ai.react.hook.context"

    schema do
      attribute :request_id, :string do
        description "Run identifier used to correlate this event with the active request."
        allow_nil? false
      end

      attribute :text, :string do
        description "Text contributed by a hook for subsequent model context."
        allow_nil? false
      end

      attribute :name, :string do
        description "Optional name identifying the hook that contributed this context."
      end
    end
  end
end
