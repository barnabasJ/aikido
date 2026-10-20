defmodule Aikido.AgentServer.Signal.CronTick do
  @moduledoc false

  use Aikido.Signal

  signal do
    type "aikido.cron_tick"

    schema do
      attribute :job_id, :term do
        allow_nil? false
        description "The logical cron job id"
      end

      attribute :message, :term do
        allow_nil? false
        description "The cron tick message payload"
      end
    end
  end
end
