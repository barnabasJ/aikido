defmodule AgentExamples.NotificationCounter.Actions.Increment do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: %{count: input.arguments.state.count + 1})
  end
end
