defmodule AgentExamples.Counter.Signals.Decrease do
  @moduledoc "Payload for `counter.decrease`."
  use Aikido.Signal

  signal do
    type "counter.decrease"
    source "/examples/counter"

    schema do
      attribute :amount, :integer do
        description "Amount applied by the typed counter signal."
        allow_nil? false
      end
    end
  end
end
