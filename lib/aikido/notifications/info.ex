defmodule Aikido.Notifications.Info do
  @moduledoc "Introspection for agent publications, subscriptions and notification projections."

  @doc "The publications declared on this resource."
  def publications(resource) do
    resource
    |> Spark.Dsl.Extension.get_entities([:notifications])
    |> Enum.filter(&match?(%Aikido.Notifications.Publication{}, &1))
  end

  @doc "Find a publication by its declared name."
  def publication(resource, name) do
    Enum.find(publications(resource), &(&1.name == name))
  end

  @doc "The subscriptions declared on this resource."
  def subscriptions(resource) do
    resource
    |> Spark.Dsl.Extension.get_entities([:notifications])
    |> Enum.filter(&match?(%Aikido.Notifications.Subscription{}, &1))
  end

  @doc "The generated calculation composing this agent's explicit notification projections."
  def projection(_resource), do: :__aikido_notification_data__

  @doc "The typed projection specifications composed by this agent's generated calculation."
  def projections(resource) do
    Spark.Dsl.Extension.get_persisted(resource, :aikido_notification_projections, [])
  end

  @doc "The generated typed signal module for a resource's named publication."
  def signal(resource, publication) do
    Module.concat([resource, Signals, publication |> to_string() |> Macro.camelize()])
  end
end
