defmodule AikidoTest.TestAgents.NotificationPublisher do
  @moduledoc "Agent publishing scoped events without changing its counter."
  use Aikido.Agent

  agent do
    name "notification_publisher"

    schema do
      attribute :count, :integer do
        description "Counter preserved while the agent publishes notifications."
        default 42
      end
    end

    route AikidoTest.TestAgents.NotificationPublisher.Signals.Publish,
          AikidoTest.TestAgents.NotificationPublisher.Actions.Publish
  end
end
