defmodule AgentExamples.Quicksort.Signals.Failed do
  @moduledoc "A child partition could not produce a sorted result."
  use Aikido.Signal

  signal do
    type "quicksort.failed"
    source "/examples/quicksort"

    schema do
      attribute :branch, :string do
        description "Child branch which failed."
        allow_nil? false
      end

      attribute :reason, :term do
        description "Reason the child could not finish sorting."
        allow_nil? false
      end
    end
  end
end
