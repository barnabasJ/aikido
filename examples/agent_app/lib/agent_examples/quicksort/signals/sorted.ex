defmodule AgentExamples.Quicksort.Signals.Sorted do
  @moduledoc "Typed payload for quicksort.sorted."
  use Aikido.Signal

  signal do
    type "quicksort.sorted"
    source "/examples/quicksort"

    schema do
      attribute :branch, :string do
        description "Child branch returning its sorted result."
        allow_nil? false
      end

      attribute :numbers, {:array, :integer} do
        description "Sorted values returned by the child."
        allow_nil? false
      end
    end
  end
end
