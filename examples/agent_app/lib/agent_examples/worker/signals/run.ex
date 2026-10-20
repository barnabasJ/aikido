defmodule AgentExamples.Worker.Signals.Run do
  @moduledoc "Payload for `worker.run`."
  use Aikido.Signal

  signal do
    type "worker.run"
    source "/examples/worker"

    schema do
      attribute :text, :string do
        description "Text to uppercase in the background worker."
        allow_nil? false
      end
    end
  end
end
