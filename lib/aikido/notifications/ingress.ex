defmodule Aikido.Notifications.Ingress do
  @moduledoc """
  Converts a declared native PubSub broadcast into a typed agent signal.

  Registrations contain resolved `topic`, `event`, and generated `signal`
  definitions. Only matching broadcasts are interpreted. Scope is supplied by
  the receiving application boundary; publisher actor, scope and tracing
  metadata are never adopted from the message.
  """

  @doc "Validate a matching publication payload and construct its receiving signal."
  def from_message(message, registrations, trusted_receiver_scope)

  def from_message(%{topic: topic, event: event, payload: payload}, registrations, scope)
      when is_binary(topic) and is_binary(event) and is_list(registrations) and is_map(scope) do
    registrations
    |> Enum.filter(&(&1.topic == topic && &1.event == event))
    |> construct_signal(payload, scope, topic, event)
  end

  def from_message(_message, _registrations, _scope), do: :ignore

  defp construct_signal([], _payload, _scope, _topic, _event), do: :ignore

  defp construct_signal([%{signal: definition}], payload, scope, topic, event) do
    case definition.new(payload, scope: scope) do
      {:ok, signal} -> {:ok, signal}
      {:error, reason} -> {:error, {:invalid_notification_payload, topic, event, reason}}
    end
  end

  defp construct_signal(_registrations, _payload, _scope, topic, event),
    do: {:error, {:ambiguous_notification_subscription, topic, event}}
end
