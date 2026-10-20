defmodule AgentExamples.Counter.Signals.Add do
  @moduledoc "Payload for `counter.add`."
  use Aikido.Signal

  signal do
    type "counter.add"
    source "/examples/counter"

    schema do
      attribute :amount, :integer, allow_nil?: false
    end
  end
end

defmodule AgentExamples.Counter.Signals.Increase do
  @moduledoc "Payload for `counter.increase`."
  use Aikido.Signal

  signal do
    type "counter.increase"
    source "/examples/counter"

    schema do
      attribute :amount, :integer, allow_nil?: false
    end
  end
end

defmodule AgentExamples.Counter.Signals.Decrease do
  @moduledoc "Payload for `counter.decrease`."
  use Aikido.Signal

  signal do
    type "counter.decrease"
    source "/examples/counter"

    schema do
      attribute :amount, :integer, allow_nil?: false
    end
  end
end
