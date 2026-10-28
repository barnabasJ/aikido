defmodule Aikido.Notifications.Receiver do
  @moduledoc "Receiving I/O boundary for declared agent publication subscriptions."

  @doc "Resolve current receiver authority, then validate a matching broadcast."
  def receive_message(message, agent) do
    registrations =
      case Map.get(agent.state, :notifications) do
        %Aikido.Notifications.Slice{registrations: registrations} -> registrations
        _ -> []
      end

    if matches?(message, registrations) do
      with :ok <- validate_current_bindings(agent, registrations),
           {:ok, scope} <- resolve_scope(agent) do
        Aikido.Notifications.Ingress.from_message(message, registrations, scope)
      end
    else
      :ignore
    end
  rescue
    error -> {:error, {:notification_receive_failed, Ash.Error.to_error_class(error)}}
  end

  defp validate_current_bindings(agent, expected) do
    case Aikido.Notifications.Registrations.resolve(agent) do
      {:ok, ^expected} -> :ok
      {:ok, _changed} -> {:error, :notification_bindings_changed}
      {:error, _} = error -> error
    end
  end

  defp resolve_scope(agent) do
    {module, function, args} =
      Spark.Dsl.Extension.get_opt(agent.agent_module, [:notifications], :scope)

    case apply(module, function, [agent | args]) do
      {:ok, scope} when is_map(scope) -> {:ok, scope}
      {:error, _} = error -> error
      _ -> {:error, :invalid_notification_scope}
    end
  end

  defp matches?(%{topic: topic, event: event}, registrations),
    do: Enum.any?(registrations, &(&1.topic == topic && &1.event == event))

  defp matches?(_, _), do: false
end
