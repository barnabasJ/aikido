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
