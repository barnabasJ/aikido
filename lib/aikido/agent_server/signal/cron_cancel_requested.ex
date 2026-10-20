defmodule Aikido.AgentServer.Signal.CronCancelRequested do
  @moduledoc """
  Ordered request to retire a logical cron job and start its shutdown.

  Queued by CronCancel alongside registration callbacks so an earlier pending
  registration is installed before cancellation resolves its current process.
  """

  use Aikido.Signal

  signal do
    type "aikido.agent.cron.cancel.requested"

    schema do
      attribute :job_id, :term do
        allow_nil? false
        description "Logical cron job id"
      end
    end
  end
end
