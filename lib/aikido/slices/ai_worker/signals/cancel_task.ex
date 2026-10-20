defmodule Aikido.Slices.AiWorker.Signals.CancelTask do
  @moduledoc "Typed payload for `harness.cancel_task`."
  use Aikido.Signal

  signal do
    type "harness.cancel_task"

    schema do
      attribute :task_id, :string do
        description "Team-assigned task identifier used to correlate acceptance, cancellation and completion."
        allow_nil? false
      end
    end
  end
end
