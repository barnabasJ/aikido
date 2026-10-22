defmodule AgentExamples.AdaptiveAssistant.Commands.SelectTools do
  @moduledoc "Selects native Ash AI tool names from application context; discovery and permission lookup belong here."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    # Simulate a bounded remote catalog request in supervised setup work.
    receive do
    after
      600 -> :ok
    end

    tools = if context.source_context[:tool_set] == "stamp", do: [:stamp], else: [:text_stats]
    {:ok, Keyword.put(input.arguments.options, :tools, tools)}
  end
end
