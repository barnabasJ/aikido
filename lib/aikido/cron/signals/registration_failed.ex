defmodule Aikido.Cron.Signals.RegistrationFailed do
  @moduledoc "Reports a cron registration.failed event to its owning slice."
  use Aikido.Signal

  signal do
    type "aikido.agent.cron.registration.failed"

    schema do
      attribute :job_id, :term do
        description "Logical job that could not start."
      end

      attribute :reason, :term do
        description "Concrete scheduler startup error."
      end

      attribute :generation, :term do
        description "Expected retry generation, or nil for a new registration."
      end
    end
  end
end
