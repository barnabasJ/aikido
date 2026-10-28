defmodule Aikido.Notifications.Directives.Subscribe do
  @moduledoc "Subscribe the current agent process to one resolved native publication topic."
  use Aikido.Directive

  typed_struct do
    field :module, :atom do
      description "Phoenix Endpoint or Phoenix.PubSub module configured by the publication."
      allow_nil? false
    end

    field :name, :atom do
      description "Named Phoenix.PubSub server, or nil when using an Endpoint."
    end

    field :topic, :string do
      description "Publication topic with all receiver-owned bindings already resolved."
      allow_nil? false
      constraints trim?: false
    end
  end

  @impl true
  def exec(%{topic: topic} = directive, _signal, _runtime) do
    case Aikido.Notifications.Transport.subscribe(directive, topic) do
      :ok -> :ok
      {:error, reason} -> {:stop, {:notification_subscription_failed, topic, reason}}
    end
  end
end
