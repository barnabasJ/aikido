defmodule AgentExamples.Worker.Actions.Failed do
  @moduledoc "Records the worker task failure and marks the work failed."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: %{status: :failed, error: input.arguments.reason})
  end
end
