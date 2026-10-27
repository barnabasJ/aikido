defmodule Aikido.Ownership.ParentBinding do
  @moduledoc "Pure parent binding validation and startup announcement descriptors."
  alias Aikido.Ownership.ParentRef

  def attach(state, %ParentRef{pid: pid} = parent, owner_pid) do
    cond do
      not is_nil(state.parent) -> reject(:already_attached, parent.id, state.parent.id)
      not is_pid(pid) or pid == owner_pid -> reject(:invalid_parent, parent.id, nil)
      true -> {:ok, %{state | parent: parent, orphaned_from: nil, parent_monitor: nil}}
    end
  end

  def attach(_, _, _), do: reject(:invalid_parent, nil, nil)

  defp reject(reason, parent_id, current_parent_id) do
    {:error,
     Aikido.Ownership.Errors.AttachmentRejected.exception(
       reason: reason,
       parent_id: parent_id,
       current_parent_id: current_parent_id
     )}
  end

  def monitor(%{parent: %{pid: pid}}),
    do: [%Aikido.Ownership.Directives.MonitorParent{pid: pid}]

  def monitor(_), do: []

  def announce(%{parent: %ParentRef{} = parent}, context) do
    [
      %Aikido.Directives.Emit{
        target: parent.pid,
        signal: %Aikido.Signal{
          type: "aikido.agent.child.started",
          data: %{
            parent_id: parent.id,
            child_id: context.agent_id,
            child_partition: context.partition,
            child_module: context.agent_module,
            tag: parent.tag,
            pid: context.agent_pid,
            meta: parent.meta || %{}
          }
        }
      }
    ]
  end

  def announce(_, _), do: []
end
