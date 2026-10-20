defmodule AgentExamples.Checklist do
  @moduledoc "Two commands share a state contract and preserve state on a business error."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_checklist"

    schema do
      attribute :items, {:array, :string} do
        description "Checklist items awaiting completion."
        allow_nil? false
        default []
        public? true
      end

      attribute :completed, :integer do
        description "Number of checklist items completed successfully."
        allow_nil? false
        default 0
        constraints min: 0
        public? true
      end
    end

    route AgentExamples.Checklist.Signals.Add, AgentExamples.Checklist.Add
    route AgentExamples.Checklist.Signals.Complete, AgentExamples.Checklist.Complete
  end
end
