defmodule Aikido.AgentServer.Signal.CronCancelRequested do
  @moduledoc """
  Ordered request to retire a logical cron job and start its shutdown.

  Queued by CronCancel alongside registration callbacks so an earlier pending
  registration is installed before cancellation resolves its current process.
  """

  use Jido.Signal,
    type: "aikido.agent.cron.cancel.requested",
    extension_policy: [{Jido.Signal.Ext.Dispatch, :optional}],
    schema: [job_id: [type: :any, required: true, doc: "Logical cron job id"]]
end
