defmodule Aikido.Notifications.Transport do
  @moduledoc """
  Subscribes the calling process through the publication's configured transport.

  An unnamed transport is a Phoenix Endpoint exposing `subscribe/1` and
  `unsubscribe/1`. A named transport is Phoenix.PubSub, whose corresponding
  functions take the PubSub server name before the topic. Membership belongs
  to the calling process and is removed by Phoenix.PubSub when it exits.
  """

  @doc "Subscribe the calling process to one resolved publication topic."
  def subscribe(%{module: module, name: nil}, topic), do: module.subscribe(topic)

  def subscribe(%{module: module, name: name}, topic), do: module.subscribe(name, topic)

  @doc "Remove the calling process's subscription to one resolved topic."
  def unsubscribe(%{module: module, name: nil}, topic), do: module.unsubscribe(topic)

  def unsubscribe(%{module: module, name: name}, topic), do: module.unsubscribe(name, topic)
end
