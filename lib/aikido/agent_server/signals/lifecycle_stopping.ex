defmodule Aikido.AgentServer.Signals.LifecycleStopping do
  @moduledoc """
  Emitted before an explicit graceful stop reaches DurableServer's final save.
  Lifecycle observers receive the termination reason through the middleware
  and action pipeline. External supervisor shutdowns use a best-effort fallback
  in `terminate/2`; that callback cannot return updated state for persistence.

  ## Fields

  - `:reason` - The requested stop reason, or the external termination reason.
  """

  use Aikido.Signal

  signal do
    type "aikido.agent.lifecycle.stopping"

    schema do
      attribute :reason, :term do
        description "Termination reason"
      end
    end
  end
end
