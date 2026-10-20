defmodule AgentExamples.Checklist do
  @moduledoc "Two commands share a state contract and preserve state on a business error."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_checklist"

    schema do
      attribute :items, {:array, :string}, allow_nil?: false, default: [], public?: true

      attribute :completed, :integer,
        allow_nil?: false,
        default: 0,
        constraints: [min: 0],
        public?: true
    end

    signal :add, AgentExamples.Checklist.Signals.Add, AgentExamples.Checklist.Add
    signal :complete, AgentExamples.Checklist.Signals.Complete, AgentExamples.Checklist.Complete
  end
end
