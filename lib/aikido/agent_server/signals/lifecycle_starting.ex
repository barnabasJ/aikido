defmodule Aikido.AgentServer.Signals.LifecycleStarting do
  @moduledoc """
  Emitted after AgentServer has received its initial or restored agent state,
  built its signal router, and bound the parent monitor. Routed through the
  middleware chain before cron jobs and post-init work start.

  Lifecycle handlers must not depend on post-init schedules or readiness.
  """

  use Aikido.Signal

  signal do
    type "aikido.agent.lifecycle.starting"
  end
end
