defmodule AgentExamples.Quicksort.Signals.RetryChild do
  @moduledoc "Retries a retained partition after a transient activation failure."
  use Aikido.Signal

  signal do
    type "quicksort.retry_child"

    schema do
      attribute :tag, :string do
        description "Partition branch to activate again."
        allow_nil? false
      end

      attribute :attempt, :integer do
        description "Retry generation used to discard stale scheduled signals."
        allow_nil? false
      end
    end
  end
end
