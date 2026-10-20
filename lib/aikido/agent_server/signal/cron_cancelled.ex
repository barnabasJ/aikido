defmodule Aikido.AgentServer.Signal.CronCancelled do
  @moduledoc """
  Completion of an intentional cron scheduler shutdown.

  The runtime retires the cancelled job's monitor, timers and saved definition
  when the ordered cancellation request is processed, before the shutdown task starts. This signal reports completion and never
  removes current ownership, so a late acknowledgment cannot affect a replacement.

  `aikido.agent.cron.died` instead reports an unintentional tracked process exit.

  ## Fields

  - `:job_id` - Logical cron job id within the agent
  - `:pid` - Retired scheduler PID, or `nil` when no job was tracked
  - `:monitor_ref` - Retired monitor reference, or `nil`
  """

  use Jido.Signal,
    type: "aikido.agent.cron.cancelled",
    extension_policy: [{Jido.Signal.Ext.Dispatch, :optional}],
    schema: [
      job_id: [type: :any, required: true, doc: "Logical cron job id within the agent"],
      pid: [type: :any, doc: "PID of the cancelled cron-job process (nil if untracked)"],
      monitor_ref: [type: :any, doc: "Monitor reference that was cleared (nil if untracked)"]
    ]
end
