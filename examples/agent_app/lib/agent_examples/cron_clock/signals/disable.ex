defmodule AgentExamples.CronClock.Signals.Disable do
  @moduledoc "Payload for the cron clock disable command."
  use Aikido.Signal

  signal do
    type "examples.cron_clock.disable"
  end
end
