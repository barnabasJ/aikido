defmodule AikidoTest.Support.PubSubNotifier do
  @moduledoc false
  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{data: data, metadata: metadata}) do
    Phoenix.PubSub.broadcast(Map.fetch!(metadata, :pubsub), Map.fetch!(metadata, :topic), data)
  end
end
