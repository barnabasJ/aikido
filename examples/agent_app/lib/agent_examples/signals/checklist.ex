defmodule AgentExamples.Checklist.Signals.Add do
  @moduledoc "Payload for `checklist.add`."
  use Aikido.Signal

  signal do
    type "checklist.add"
    source "/examples/checklist"

    schema do
      attribute :item, :string, allow_nil?: false
    end
  end
end

defmodule AgentExamples.Checklist.Signals.Complete do
  @moduledoc "Payload for `checklist.complete`."
  use Aikido.Signal

  signal do
    type "checklist.complete"
    source "/examples/checklist"

    schema do
      attribute :item, :string, allow_nil?: false
    end
  end
end
