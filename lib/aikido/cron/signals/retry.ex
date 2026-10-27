defmodule Aikido.Cron.Signals.Retry do
  @moduledoc "Reports a cron retry event to its owning slice."
  use Aikido.Signal

  signal do
    type "aikido.agent.cron.retry"

    schema do
      attribute :job_id, :term do
        description "Logical job awaiting restart."
      end

      attribute :generation, :term do
        description "Registration generation that scheduled this retry."
      end
    end
  end
end
