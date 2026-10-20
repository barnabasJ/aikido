defmodule Aikido.Slices.AiReact.Signals.HookCompleted do
  @moduledoc "Typed payload for `ai.react.hook.completed`."
  use Aikido.Signal

  signal do
    type "ai.react.hook.completed"

    schema do
      attribute :request_id, :string do
        description "Run identifier used to correlate this event with the active request."
        allow_nil? false
      end

      attribute :token, :integer do
        description "Sequence token identifying the pending hook continuation."
        allow_nil? false
      end

      attribute :name, :string do
        description "Name of the hook whose pending continuation has completed."
        allow_nil? false
      end

      attribute :mode, :atom do
        description "Hook execution mode determining whether completion gates the run."
        allow_nil? false
        constraints one_of: [:sync, :async]
      end

      attribute :result, :term do
        description "Hook decision or value returned by the completed callback."
      end

      attribute :reason, :term do
        description "Failure reason returned instead of a hook result."
      end
    end
  end
end
