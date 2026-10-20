defmodule Aikido.Signals.AiReact.HookCompleted do
  @moduledoc "Typed payload for `ai.react.hook.completed`."
  use Aikido.Signal

  signal do
    type "ai.react.hook.completed"

    schema do
      attribute :request_id, :string, allow_nil?: false

      attribute :token, :integer, allow_nil?: false

      attribute :name, :string, allow_nil?: false

      attribute :mode, :atom, allow_nil?: false, constraints: [one_of: [:sync, :async]]

      attribute :result, :term

      attribute :reason, :term
    end
  end
end
