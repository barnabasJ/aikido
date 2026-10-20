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

  A clean stop prevents DurableServer recovery. The resource's persistence policy
  determines whether its snapshot is retained for a later explicit activation.
  """

  use Aikido.Directive

  typed_struct do
    field :tag, :term do
      allow_nil? false
      description "Tag of the child to stop"
    end

    field :reason, :term do
      allow_nil? false
      default :normal
      description "Reason for stopping"
    end
  end

  require Logger

  @impl true
  def exec(%{tag: tag, reason: reason}, input_signal, state) do
    case Map.get(state.children, tag) do
      nil ->
        Logger.debug("AgentServer #{state.id} cannot stop child #{inspect(tag)}: not found")

      %{pid: pid} ->
        Logger.debug(
          "AgentServer #{state.id} stopping child #{inspect(tag)} with reason #{inspect(reason)}"
        )

        signal =
          "aikido.agent.stop"
          |> Aikido.Signal.new!(%{reason: normalize_stop_reason(reason)},
            source: "/agent/#{state.id}"
          )
          |> Aikido.Signal.inherit(input_signal)

        Aikido.AgentServer.cast(pid, signal)
    end

    :ok
  end

  # Clean shutdown prevents automatic recovery; preserve custom reasons inside it.
  defp normalize_stop_reason(:normal), do: :normal
  defp normalize_stop_reason(:shutdown), do: :shutdown
  defp normalize_stop_reason({:shutdown, _} = reason), do: reason
  defp normalize_stop_reason(reason), do: {:shutdown, reason}
end
