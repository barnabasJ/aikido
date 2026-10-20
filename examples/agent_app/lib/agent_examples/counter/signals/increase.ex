defmodule AgentExamples.Counter.Signals.Increase do
  @moduledoc "Payload for `counter.increase`."
  use Aikido.Signal

  signal do
    type "counter.increase"
    source "/examples/counter"

    schema do
      attribute :amount, :integer do
        description "Amount applied by the typed counter signal."
        allow_nil? false
      end
    end
  end
end
