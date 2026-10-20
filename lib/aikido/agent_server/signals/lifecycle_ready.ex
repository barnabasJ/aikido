defmodule Aikido.AgentServer.Signals.LifecycleReady do
  @moduledoc """
  Emitted after AgentServer finishes post-init work: schedules are registered
  and the parent is notified. Observers see the restored agent state and the
  active runtime. Routed actions may return directives for post-boot I/O.
  """

  use Aikido.Signal

  signal do
    type "aikido.agent.lifecycle.ready"
  end
end
