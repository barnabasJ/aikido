defmodule AikidoTest.TestAgents.NotificationPublisher.Signals.Publish do
  use Aikido.Signal

  signal do
    type "test.broadcast"

    schema do
      attribute :pubsub, :atom do
        description "Application-owned PubSub server receiving the notification."
        allow_nil? false
      end

      attribute :topic, :string do
        description "Topic on which the agent publishes the event."
        allow_nil? false
      end

      attribute :signal_type, :string do
        description "Type of the event delivered to subscribers."
        allow_nil? false
      end

      attribute :payload, :map do
        description "Event payload delivered to subscribers."
        default %{}
      end

      attribute :source, :string do
        description "Source of the outgoing event."
        default "/broadcast"
      end
    end
  end
end
