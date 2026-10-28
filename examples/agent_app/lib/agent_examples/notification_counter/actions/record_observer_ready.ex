defmodule AgentExamples.NotificationCounter.Actions.RecordObserverReady do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: %{enabled: true, result: "Observer subscribed"})
  end
end
