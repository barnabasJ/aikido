defmodule AgentExamples.NotificationCounter.Signals.Increment do
  use Aikido.Signal

  signal do
    type "example.notifications.increment"
  end
end
