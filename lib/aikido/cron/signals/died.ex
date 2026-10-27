defmodule Aikido.Cron.Signals.Died do
  @moduledoc "Scheduler process exit translated into a signal; the owning slice decides whether to restart."

  use Aikido.Signal

  signal do
    type "aikido.agent.cron.died"

    schema do
      attribute :job_id, :term do
        allow_nil? false
        description "Logical cron job id within the agent"
      end

      attribute :pid, :term do
        allow_nil? false
        description "PID of the cron-job process that exited"
      end

      attribute :reason, :term do
        allow_nil? false
        description "Exit reason from the cron-job process"
      end
    end
  end
end
