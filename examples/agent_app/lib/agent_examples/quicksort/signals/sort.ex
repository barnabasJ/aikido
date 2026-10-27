defmodule AgentExamples.Quicksort.Signals.Sort do
  @moduledoc "Typed payload for quicksort.sort."
  use Aikido.Signal

  signal do
    type "quicksort.sort"
    source "/examples/quicksort"

    schema do
      attribute :numbers, {:array, :integer} do
        description "Numbers to sort in this partition."
        allow_nil? false
      end

      attribute :topic, :string do
        description "PubSub topic shared by this sorting tree."
        allow_nil? false
      end
    end
  end
end
