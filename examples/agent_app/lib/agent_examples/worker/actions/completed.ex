defmodule AgentExamples.Worker.Actions.Completed do
  @moduledoc "Records the result returned by the worker task and marks it completed."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: %{status: :completed, result: input.arguments.result})
  end
end
