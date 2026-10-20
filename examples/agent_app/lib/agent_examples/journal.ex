defmodule AgentExamples.Journal do
  @moduledoc "An embedded resource whose Ash action returns the next slice state."
  use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Ash.Slice]

  attributes do
    attribute :entries, {:array, :string} do
      description "Journal entries appended in their original order."
      public? true
      allow_nil? false
      default []
    end
  end

  slice do
    name "example_journal"
    route AgentExamples.Journal.Signals.Append, AgentExamples.Journal.AppendEntry
  end
end
