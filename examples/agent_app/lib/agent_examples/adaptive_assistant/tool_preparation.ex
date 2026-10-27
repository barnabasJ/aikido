defmodule AgentExamples.AdaptiveAssistant.ToolPreparation do
  @moduledoc "Native application action configuring the tools exposed for this run's current permission context."
  use Ash.Resource, domain: AgentExamples.Agents

  actions do
    action :prepare, :term do
      argument :options, {:array, :tuple},
        constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]]

      argument :metadata, :map
      run AgentExamples.AdaptiveAssistant.Commands.SelectTools
    end
  end
end
