defmodule Aikido.AgentServer.Signals.LifecycleStopping do
  @moduledoc """
  Emitted before an explicit graceful stop reaches DurableServer's final save.
  Lifecycle observers receive the termination reason through the middleware
  and action pipeline with the current stop command or input signal's scope.
  Explicit prepared stops return cleanup failures to the caller and keep the
  process alive. A Stop directive still terminates after reporting cleanup errors.
  External supervisor shutdowns use a best-effort fallback without caller
  authority in `terminate/2`; that callback cannot return updated state for persistence.

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
