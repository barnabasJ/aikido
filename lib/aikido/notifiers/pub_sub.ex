defmodule Aikido.Notifiers.PubSub do
  @moduledoc """
  Native Ash notifier for an application-owned Phoenix PubSub server.

  Broadcasts `notification.data` using the `:pubsub` server and `:topic` in
  notification metadata. Applications start and subscribe to their own server.
  Resource-configured publications can use `Ash.Notifier.PubSub` instead.
  """
  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{data: data, metadata: metadata}) do
    Phoenix.PubSub.broadcast(Map.fetch!(metadata, :pubsub), Map.fetch!(metadata, :topic), data)
  end
end
