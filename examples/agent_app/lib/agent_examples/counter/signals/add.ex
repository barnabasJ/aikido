defmodule AgentExamples.Counter.Signals.Add do
  @moduledoc "Payload for `counter.add`."
  use Aikido.Signal

  signal do
    type "counter.add"
    source "/examples/counter"

    schema do
      attribute :amount, :integer do
        description "Amount applied by the typed counter signal."
        allow_nil? false
      end
    end
  end
end
