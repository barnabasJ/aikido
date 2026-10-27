defmodule Aikido.Cron.Signals.CancelRequested do
  @moduledoc "Ordered request for the cron slice to detach a schedule and release its scheduler."

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
