defmodule Aikido.Actions.Broadcast do
  @moduledoc """
  Pure reducer preparing a native Ash PubSub notification.

  Accepts the application-owned `pubsub` server, `topic`, `signal_type`,
  `payload` and `source`; preserves `state` and returns a `Notify` directive.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    signal = %Aikido.Signal{
      id: nil,
      type: input.arguments.signal_type,
      data: input.arguments.payload,
      source: input.arguments.source
    }

    notification = %Ash.Notifier.Notification{
      for: Aikido.Notifiers.PubSub,
      data: signal,
      metadata: %{pubsub: input.arguments.pubsub, topic: input.arguments.topic}
    }

    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [%Aikido.Directives.Notify{notification: notification}]
    )
  end
end
