defmodule AgentExamples.NotificationCounter.Observer.Actions.AdoptCount do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    count = input.arguments.metrics

    if count == input.arguments.state.count do
      Aikido.Types.ActionResult.new(changes: nil)
    else
      signal = %Aikido.Signal{type: "example.notifications.observed", data: %{count: count}}
      effect = Aikido.Directives.emit(signal, input.context.aikido.parent.pid)
      Aikido.Types.ActionResult.new(changes: %{count: count}, directives: [effect])
    end
  end
end
