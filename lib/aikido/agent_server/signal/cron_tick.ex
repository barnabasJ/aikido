defmodule Aikido.AgentServer.Signal.CronTick do
  @moduledoc false

  use Aikido.Signal

  signal do
    type "aikido.cron_tick"

    schema do
      attribute :job_id, :term, allow_nil?: false, description: "The logical cron job id"
      attribute :message, :term, allow_nil?: false, description: "The cron tick message payload"
    end
  end
end
