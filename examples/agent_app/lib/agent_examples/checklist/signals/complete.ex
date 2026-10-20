defmodule AgentExamples.Checklist.Signals.Complete do
  @moduledoc "Payload for `checklist.complete`."
  use Aikido.Signal

  signal do
    type "checklist.complete"
    source "/examples/checklist"

    schema do
      attribute :item, :string do
        description "Checklist item selected for this command."
        allow_nil? false
      end
    end
  end
end
