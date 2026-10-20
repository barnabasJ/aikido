defmodule Aikido.Signals.AiWorker.CancelTask do
  @moduledoc "Typed payload for `harness.cancel_task`."
  use Aikido.Signal

  signal do
    type "harness.cancel_task"

    schema do
      attribute :task_id, :string, allow_nil?: false
    end
  end
end
