defmodule AgentExamples.NotificationCounter.Observer do
  @moduledoc "Subscribes to its parent's native publication and adopts the typed counter value."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Agent.Extension]

  agent do
    name "notification_observer"
    persistence :temporary

    schema do
      attribute :publisher_id, :string do
        description "Stable publisher identity used to bind the subscription topic."
        allow_nil? false
      end

      attribute :count, :integer do
        description "Latest count received through native Ash PubSub."
      end
    end

    route AgentExamples.NotificationCounter.Signals.Changed,
          AgentExamples.NotificationCounter.Observer.Actions.AdoptCount, public?: false
  end

  notifications do
    scope({AgentExamples.NotificationCounter.Observer.Scope, :resolve, []})

    subscribe AgentExamples.NotificationCounter, :changed do
      bindings(id: :publisher_id)
    end
  end
end
