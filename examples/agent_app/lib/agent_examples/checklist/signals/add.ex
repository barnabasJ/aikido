defmodule AgentExamples.Checklist.Signals.Add do
  @moduledoc "Payload for `checklist.add`."
  use Aikido.Signal

  signal do
    type "checklist.add"
    source "/examples/checklist"

    schema do
      attribute :item, :string do
        description "Checklist item selected for this command."
        allow_nil? false
      end
    end
  end
end
