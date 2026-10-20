defmodule AgentExamples.Journal.Signals.Append do
  @moduledoc "Payload for `journal.append`."
  use Aikido.Signal

  signal do
    type "journal.append"
    source "/examples/journal"

    schema do
      attribute :text, :string, allow_nil?: false
    end
  end
end
