defmodule AgentExamples.ResilientAssistant.Tools.RejectWork do
  @moduledoc "Returns a deterministic tool error without performing external work."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context) do
    {:error,
     AgentExamples.AI.Tools.ToolFailure.failure(
       "example_tool_unavailable",
       "This example tool deliberately fails to demonstrate error recovery limits.",
       "Repeating this call cannot succeed. Use another tool or report the intentional failure."
     )}
  end
end
