defmodule Aikido.Notifications.Registrations do
  @moduledoc "Resolves declared subscription topics from receiver-owned attributes."
  alias Aikido.Notifications.Info

  @doc "Resolve subscriptions without inheriting any publisher authority."
  def resolve(agent) do
    attributes = Aikido.Agent.resource_attributes(agent)

    agent.agent_module
    |> Info.subscriptions()
    |> Enum.reduce_while({:ok, []}, fn subscription, {:ok, resolved} ->
      with {:ok, registration} <- registration(subscription, attributes) do
        if Enum.any?(
             resolved,
             &(&1.topic == registration.topic && &1.event == registration.event)
           ) do
          {:halt,
           {:error,
            {:ambiguous_notification_subscription, registration.topic, registration.event}}}
        else
          {:cont, {:ok, resolved ++ [registration]}}
        end
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp registration(subscription, attributes) do
    publication = Info.publication(subscription.resource, subscription.publication)

    with {:ok, topic} <- topic(publication.topic, subscription.bindings, attributes) do
      {:ok,
       %{
         topic: topic,
         event: to_string(subscription.publication),
         signal: Info.signal(subscription.resource, subscription.publication),
         module: Spark.Dsl.Extension.get_opt(subscription.resource, [:notifications], :pubsub),
         name: Spark.Dsl.Extension.get_opt(subscription.resource, [:notifications], :pubsub_name)
       }}
    end
  end

  defp topic(template, bindings, attributes) do
    template
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn
      literal, {:ok, parts} when is_binary(literal) ->
        {:cont, {:ok, parts ++ [literal]}}

      field, {:ok, parts} when is_atom(field) ->
        with {:ok, receiver_field} <- Keyword.fetch(bindings, field),
             {:ok, value} when not is_nil(value) <- Map.fetch(attributes, receiver_field) do
          {:cont, {:ok, parts ++ [to_string(value)]}}
        else
          _ -> {:halt, {:error, {:missing_notification_binding, field}}}
        end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.join(parts, ":")}
      error -> error
    end
  end
end
