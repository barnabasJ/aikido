defmodule AgentExamples.Counter do
  @moduledoc "Typed signals, a shared union handler, and a wildcard signal counter."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_counter"

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        allow_nil? false
        default 0
        public? true
      end

      attribute :signals_seen, :integer do
        description "Total signals observed by the wildcard handler."
        allow_nil? false
        default 0
        public? true
      end
    end

    route AgentExamples.Counter.Signals.Add, AgentExamples.Counter.Increment

    route [AgentExamples.Counter.Signals.Increase, AgentExamples.Counter.Signals.Decrease],
          AgentExamples.Counter.Adjust

    route "**", AgentExamples.Counter.CountAll
  end
end
