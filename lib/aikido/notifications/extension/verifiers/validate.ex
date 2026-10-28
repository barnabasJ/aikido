defmodule Aikido.Notifications.Extension.Verifiers.Validate do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Aikido.Notifications.Info

  @impl true
  def verify(dsl) do
    resource = Spark.Dsl.Verifier.get_persisted(dsl, :module)
    publications = Info.publications(dsl)
    subscriptions = Info.subscriptions(dsl)

    if publications != [] && is_nil(Spark.Dsl.Extension.get_opt(dsl, [:notifications], :pubsub)) do
      fail!(resource, "Publications require a pubsub transport module")
    end

    modules = Enum.map(publications, &Info.signal(resource, &1.name))

    if length(modules) != length(Enum.uniq(modules)),
      do: fail!(resource, "Publication names must generate distinct signal module names")

    for mount <- Aikido.Agent.Info.slice_instances(dsl),
        mount.module == Aikido.Notifications.Slice do
      if mount.path != :notifications,
        do: fail!(resource, "The subscription slice must use the reserved :notifications mount")
    end

    for publication <- publications do
      validate_topic!(resource, publication.topic)
    end

    for projection <- Info.projections(dsl) do
      calculation = Ash.Resource.Info.calculation(projection.resource, :notification_data)

      if projection.type in [nil, :auto] do
        fail!(resource, "notification_data calculations require an explicit native Ash type")
      end

      if Enum.any?(calculation.arguments, &(!&1.allow_nil? && is_nil(&1.default))) do
        fail!(resource, "notification_data calculations cannot require runtime arguments")
      end
    end

    if subscriptions != [] && is_nil(Spark.Dsl.Extension.get_opt(dsl, [:notifications], :scope)) do
      fail!(resource, "Subscriptions require a scope MFA resolving current receiving authority")
    end

    for subscription <- subscriptions do
      validate_subscription!(resource, dsl, subscription)
    end

    :ok
  end

  defp validate_subscription!(resource, dsl, subscription) do
    case Code.ensure_compiled(subscription.resource) do
      {:module, _} -> :ok
      _ -> fail!(resource, "Cannot load subscription publisher #{inspect(subscription.resource)}")
    end

    publication = Info.publication(subscription.resource, subscription.publication)

    if is_nil(publication),
      do:
        fail!(
          resource,
          "Unknown publication #{inspect(subscription.resource)}.#{subscription.publication}"
        )

    validate_topic!(resource, publication.topic)
    fields = publication.topic |> List.wrap() |> Enum.filter(&is_atom/1) |> Enum.uniq()

    if Enum.sort(Keyword.keys(subscription.bindings)) != Enum.sort(fields) do
      fail!(resource, "Subscription bindings must name exactly the publisher's topic attributes")
    end

    for {_publisher_field, receiver_field} <- subscription.bindings do
      if is_nil(Ash.Resource.Info.attribute(dsl, receiver_field)) do
        fail!(
          resource,
          "Unknown receiving attribute #{inspect(receiver_field)} in subscription binding"
        )
      end
    end
  end

  defp validate_topic!(resource, topic) do
    if List.wrap(topic) == [] || !Enum.all?(List.wrap(topic), &(is_binary(&1) || is_atom(&1))) do
      fail!(
        resource,
        "Agent subscriptions support a single topic template of strings and attribute atoms"
      )
    end
  end

  defp fail!(resource, message) do
    raise Spark.Error.DslError, module: resource, path: [:notifications], message: message
  end
end
