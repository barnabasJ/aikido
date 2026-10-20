defmodule AgentExamples.Worker.Signals.Completed do
  @moduledoc "Payload for `worker.completed`."
  use Aikido.Signal

  signal do
    type "worker.completed"
    source "/examples/worker"

    schema do
      attribute :result, :string do
        description "Uppercase text returned by the background task."
        allow_nil? false
      end
    end
  end
end
