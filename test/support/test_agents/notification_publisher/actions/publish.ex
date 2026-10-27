defmodule AikidoTest.TestAgents.NotificationPublisher.Actions.Publish do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    notification = %Ash.Notifier.Notification{
      for: AikidoTest.Support.PubSubNotifier,
      data: %Aikido.Signal{
        type: input.arguments.signal_type,
        data: input.arguments.payload,
        source: input.arguments.source
      },
      metadata: %{pubsub: input.arguments.pubsub, topic: input.arguments.topic}
    }

    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [%Aikido.Directives.Notify{notification: notification}]
    )
  end
end
