defmodule AgentExamples.AI.Tools.Actions.Stamp do
  @moduledoc "Returns the supplied text with this caller's runtime label."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    {:ok, %{label: Map.get(input.context, :stamp_label, "runtime"), text: input.arguments.text}}
  end
end
