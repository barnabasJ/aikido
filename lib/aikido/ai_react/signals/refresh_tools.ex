defmodule Aikido.AiReact.Signals.RefreshTools do
  @moduledoc "Updates native tool configuration and requests preparation at the next safe model boundary."
  use Aikido.Signal

  signal do
    type "ai.react.refresh_tools"

    schema do
      attribute :tools, {:array, :atom} do
        description "Replacement Ash AI tool names; omitted values retain the current selection."
      end

      attribute :tool_options, {:array, :tuple} do
        constraints items: [fields: [key: [type: :atom], value: [type: :term]]]
        description "Replacement native Ash AI options, including application-owned extra tools."
      end

      attribute :tool_context, :map do
        description "Application context merged into tool execution and preparation without replacing caller scope."
        default %{}
        allow_nil? false
      end
    end
  end
end
