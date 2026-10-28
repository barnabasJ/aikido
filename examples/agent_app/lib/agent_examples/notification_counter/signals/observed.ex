defmodule AgentExamples.NotificationCounter.Signals.Observed do
  use Aikido.Signal

  signal do
    type "example.notifications.observed"

    schema do
      attribute :count, :integer do
        description "Published count adopted by the observer."
        allow_nil? false
      end
    end
  end
end
