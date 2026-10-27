defmodule Aikido.Cron.Signals.Registered do
  @moduledoc "Scheduler startup result adopted by the owning cron slice action."

  use Aikido.Signal

  signal do
    type "aikido.agent.cron.registered"

    schema do
      attribute :generation, :term do
        description "Expected retry generation; nil denotes a new registration."
      end

      attribute :job_id, :term do
        allow_nil? false
        description "Logical cron job id within the agent"
      end

      attribute :pid, :term do
        allow_nil? false
        description "PID of the spawned cron-job process"
      end

      attribute :monitor_ref, :term do
        allow_nil? false
        description "Monitor reference for the cron-job process"
      end

      attribute :cron_spec, :term do
        allow_nil? false
        description "Validated cron spec map"
      end

      attribute :runtime_spec, :term do
        allow_nil? false
        description "%Aikido.Cron.RuntimeSpec{} carrying scheduler details"
      end
    end
  end
end
