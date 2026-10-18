defmodule AgentExamples.Counter do
  @moduledoc "Typed update arguments become signals; a pure action increments state."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_counter"

    schema do
      attribute :count, :integer, allow_nil?: false, default: 0, public?: true
    end

    signal :add, "counter.add", AgentExamples.Actions.Add
  end
end
