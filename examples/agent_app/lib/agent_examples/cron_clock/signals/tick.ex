defmodule AgentExamples.CronClock.Signals.Tick do
  @moduledoc "Payload for the cron clock tick command."
  use Aikido.Signal

  signal do
    type "examples.cron_clock.tick"
  end
end
