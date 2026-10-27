defmodule AgentExamples.CronClock.Signals.Enable do
  @moduledoc "Payload for the cron clock enable command."
  use Aikido.Signal

  signal do
    type "examples.cron_clock.enable"
  end
end
