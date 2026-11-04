defmodule Aikido.AiWorker.Signals.RequestRejected do
  @moduledoc "A confirmed native failure processing the pending worker's AI request."
  use Aikido.Signal

  signal do
    type "harness.ai.request_rejected"

    schema do
      attribute :task_id, :string do
        description "Task whose inner AI request was rejected."
        allow_nil? false
      end

      attribute :member, :term do
        description "Assigning team's member name."
        allow_nil? false
      end

      attribute :attempt, :string do
        description "Member incarnation that owns the pending assignment."
        allow_nil? false
      end

      attribute :failure, Aikido.AiWorker.Types.RequestFailure do
        description "Public rejection classification without raw action errors."
        allow_nil? false
      end
    end
  end
end
