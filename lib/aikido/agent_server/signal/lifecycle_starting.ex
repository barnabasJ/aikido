defmodule Aikido.AgentServer.Signal.LifecycleStarting do
  @moduledoc """
  Emitted after AgentServer has received its initial or restored agent state,
  built its signal router, and bound the parent monitor. Routed through the
  middleware chain before cron jobs and post-init work start.

  Lifecycle handlers must not depend on post-init schedules or readiness.
  """

  use Jido.Signal,
    type: "aikido.agent.lifecycle.starting",
    extension_policy: [
      {Jido.Signal.Ext.Trace, :optional},
      {Jido.Signal.Ext.Dispatch, :optional}
    ],
    schema: []
end
