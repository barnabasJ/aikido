defmodule Aikido.Notifications.Slice do
  @moduledoc """
  Owns resolved subscription topics for one agent activation.

  Registrations are rebuilt from declarations and current receiver attributes on
  activation. PubSub delivery is best effort and does not replay missed events.
  """
  use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Slice.Extension]

  slice do
    name "notifications"

    schema do
      attribute :registrations, {:array, :map} do
        description "Resolved transport topics registered by this agent process."
        allow_nil? false
        default []
      end
    end

    route Aikido.AgentServer.Signals.LifecycleStarting, Aikido.Notifications.Actions.Subscribe,
      public?: false

    route Aikido.AgentServer.Signals.LifecycleStopping, Aikido.Notifications.Actions.Unsubscribe,
      public?: false
  end

  @doc false
  def externalize(state), do: Map.put(state, :registrations, [])

  @doc false
  def reinstate(state), do: externalize(state)
end
