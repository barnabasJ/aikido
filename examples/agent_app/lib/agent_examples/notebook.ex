defmodule AgentExamples.Notebook do
  @moduledoc "Own state plus a mounted, embedded Ash slice."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_notebook"

    schema do
      attribute :title, :string do
        description "Title displayed above the notebook journal."
        allow_nil? false
        default "Notes"
        public? true
      end
    end

    slice :journal, AgentExamples.Journal
  end
end
