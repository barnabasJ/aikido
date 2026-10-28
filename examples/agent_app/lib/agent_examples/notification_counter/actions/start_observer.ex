defmodule AgentExamples.NotificationCounter.Actions.StartObserver do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    id = input.context.aikido.agent.id

    Aikido.Types.ActionResult.new(
      changes: nil,
      directives: [
        Aikido.Directives.SpawnAgent.new!(
          agent: AgentExamples.NotificationCounter.Observer,
          tag: :observer,
          opts: %{initial_state: %{publisher_id: id}}
        )
      ]
    )
  end
end
