defmodule AgentExamples.AdaptiveAssistant.ModelPreparation do
  @moduledoc "Native per-attempt model preparation, separate from tool registry preparation."
  use Ash.Resource, domain: AgentExamples.Agents

  actions do
    action :prepare, Aikido.AiReact.Types.ModelRequest do
      argument :model, :term, allow_nil?: false

      argument :options, {:array, :tuple},
        allow_nil?: false,
        constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]]

      run AgentExamples.AdaptiveAssistant.Commands.PrepareModel
    end
  end
end
