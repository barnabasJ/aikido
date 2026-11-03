defmodule Aikido.Ownership.Delivery do
  @moduledoc "Correlates a child's announcement with its actual activation parent binding."

  def permitted?(
        runtime,
        %{parent: %{id: parent_id, pid: parent_pid, tag: tag}} = sender,
        %Aikido.Signal{type: "aikido.agent.child.started", data: data},
        _correlation
      ) do
    parent_id == runtime.id && parent_pid == self() &&
      sender.aikido == runtime.aikido && sender.partition == runtime.partition &&
      data.parent_id == parent_id && data.tag == tag &&
      data.child_id == sender.id && data.pid == sender.pid &&
      data.child_module == sender.resource && data.child_partition == sender.partition
  end

  def permitted?(_runtime, _sender, _signal, _correlation), do: false
end
