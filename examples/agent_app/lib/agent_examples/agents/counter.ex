defmodule AgentExamples.Counter do
  @moduledoc "Typed action arguments become signals; a pure action increments state."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_counter"

    schema do
      attribute :count, :integer, allow_nil?: false, default: 0, public?: true
    end

    signal :add, "counter.add", :add
  end

  actions do
    action :add, Aikido.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :amount, :integer, allow_nil?: false
      run AgentExamples.Counter.Implementation
    end
  end
end
