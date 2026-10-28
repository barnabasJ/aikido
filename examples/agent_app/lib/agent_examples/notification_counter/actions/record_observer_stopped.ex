defmodule AgentExamples.NotificationCounter.Actions.RecordObserverStopped do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(changes: %{enabled: false, result: "Observer stopped"})
  end
end
