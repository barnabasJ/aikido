defmodule Aikido.Cron.Signals.Restarted do
  @moduledoc "Acknowledges successful adoption of a replacement scheduler after an abnormal exit."

  use Aikido.Signal

  signal do
    type "aikido.agent.cron.restarted"

    schema do
      attribute :job_id, :term do
        allow_nil? false
        description "Logical cron job id within the agent"
      end

      attribute :pid, :term do
        allow_nil? false
        description "PID of the freshly-spawned cron-job process"
      end
    end
  end
end
