defmodule AgentExamples.NotificationCounter.Actions.Acknowledge do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: %{result: "Observer adopted #{input.arguments.count}"})
  end
end
