defmodule Aikido.AgentServer.Signal.LifecycleStopping do
  @moduledoc """
  Emitted at the top of `terminate/2`, before owned runtime processes are
  stopped. Lifecycle observers receive the termination reason through the
  middleware and action pipeline. DurableServer owns snapshot persistence.

  ## Fields

  - `:reason` - The termination reason passed to `terminate/2`.
  """

  use Jido.Signal,
    type: "aikido.agent.lifecycle.stopping",
    extension_policy: [{Jido.Signal.Ext.Dispatch, :optional}],
    schema: [
      reason: [type: :any, required: false, doc: "Termination reason"]
    ]
end
