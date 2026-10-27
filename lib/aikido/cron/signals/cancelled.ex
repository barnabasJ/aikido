defmodule Aikido.Cron.Signals.Cancelled do
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

  use Aikido.Signal

  signal do
    type "aikido.agent.cron.cancelled"

    schema do
      attribute :job_id, :term do
        allow_nil? false
        description "Logical cron job id within the agent"
      end

      attribute :pid, :term do
        description "PID of the cancelled cron-job process (nil if untracked)"
      end

      attribute :monitor_ref, :term do
        description "Monitor reference that was cleared (nil if untracked)"
      end
    end
  end
end
