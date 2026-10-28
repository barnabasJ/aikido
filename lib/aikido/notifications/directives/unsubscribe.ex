defmodule Aikido.Notifications.Directives.Unsubscribe do
  @moduledoc "Remove the current agent process's subscription to one native publication topic."
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
      description "Previously resolved publication topic whose membership should be removed."
      allow_nil? false
      constraints trim?: false
    end
  end

  @impl true
  def exec(%{topic: topic} = directive, _signal, _runtime) do
    case Aikido.Notifications.Transport.unsubscribe(directive, topic) do
      :ok -> :ok
      {:error, reason} -> {:stop, {:notification_unsubscription_failed, topic, reason}}
    end
  end
end
