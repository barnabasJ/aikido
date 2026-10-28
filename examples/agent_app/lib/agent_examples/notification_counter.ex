defmodule AgentExamples.NotificationCounter do
  @moduledoc "A public counter publishing an explicit calculation to a subscribed child agent."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Agent.Extension]

  agent do
    name "notification_counter"
    path :metrics
    persistence :temporary

    schema do
      attribute :count, :integer do
        description "Counter value exposed by the explicit notification calculation."
        allow_nil? false
        default 0
      end

      attribute :enabled, :boolean do
        description "Whether the observer has completed startup and subscribed."
        allow_nil? false
        default false
      end

      attribute :result, :string do
        description "Latest acknowledgement received from the observing agent."
      end
    end

    route AgentExamples.NotificationCounter.Signals.Increment,
          AgentExamples.NotificationCounter.Actions.Increment

    route AgentExamples.NotificationCounter.Signals.Observed,
          AgentExamples.NotificationCounter.Actions.Acknowledge, public?: false

    route Aikido.AgentServer.Signals.LifecycleReady,
          AgentExamples.NotificationCounter.Actions.StartObserver, public?: false

    route Aikido.Ownership.Signals.ChildStarted,
          AgentExamples.NotificationCounter.Actions.RecordObserverReady, public?: false

    route Aikido.Ownership.Signals.ChildExit,
          AgentExamples.NotificationCounter.Actions.RecordObserverStopped, public?: false
  end

  calculations do
    calculate :notification_data, :integer, expr(count)
  end

  notifications do
    pubsub(Phoenix.PubSub)
    pubsub_name(AgentExamples.PubSub)

    publish :changed do
      topic(["aikido", "example-counter", :id])
    end
  end
end
