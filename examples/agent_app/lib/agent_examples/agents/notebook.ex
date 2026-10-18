defmodule AgentExamples.Notebook do
  @moduledoc "Own state plus a mounted, embedded Ash slice."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_notebook"

    schema do
      attribute :title, :string, allow_nil?: false, default: "Notes", public?: true
    end

    slice :journal, AgentExamples.Journal
  end
end
