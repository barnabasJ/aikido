defmodule AgentExamples.Worker.Signals.Failed do
  @moduledoc "Payload for `worker.failed`."
  use Aikido.Signal

  signal do
    type "worker.failed"
    source "/examples/worker"

    schema do
      attribute :reason, :term do
        description "Failure reason returned by the background task."
        allow_nil? false
      end
    end
  end
end
