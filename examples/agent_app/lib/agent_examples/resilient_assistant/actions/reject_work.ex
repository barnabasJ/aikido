defmodule AgentExamples.ResilientAssistant.Actions.RejectWork do
  @moduledoc "Returns a deterministic tool error without performing external work."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context), do: {:error, "Example tool unavailable"}
end
