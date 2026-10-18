defmodule Aikido.Directives.StopChild do
  @moduledoc """
  Request that a tracked child agent stop gracefully.

  This directive provides symmetric lifecycle control for child agents
  spawned via `SpawnAgent`. It sends a shutdown signal to the child,
  allowing it to terminate cleanly.

  The child is identified by its `tag` (the key used in `SpawnAgent`).
  If the child is not found, the directive is a no-op.

  ## Fields

  - `tag` - Tag of the child to stop (must match a key in the children map)
  - `reason` - Reason for stopping (default: `:normal`)

  ## Examples

      # Stop a worker by tag
      %StopChild{tag: :worker_1}

      # Stop with a specific reason
      %StopChild{tag: :processor, reason: :shutdown}

  ## Behavior

  The runtime sends a `aikido.agent.stop` signal to the child process,
  which triggers a graceful shutdown. The child's exit will be delivered
  back to the parent as a `aikido.agent.child.exit` signal.

  `SpawnAgent` children default to `restart: :transient`, so a normal
  `StopChild` shutdown removes the child instead of immediately restarting it.
  Custom reasons are wrapped as `{:shutdown, reason}` so transient children
  are still removed cleanly.
  """

  use Aikido.Directive

  typed_struct do
    field :tag, :term, allow_nil?: false, description: "Tag of the child to stop"
    field :reason, :term, allow_nil?: false, default: :normal, description: "Reason for stopping"
  end

  alias Aikido.AgentServer.StopChildRuntime

  @impl true
  def exec(%{tag: tag, reason: reason}, input_signal, state) do
    StopChildRuntime.exec(tag, reason, input_signal, state)
  end
end
