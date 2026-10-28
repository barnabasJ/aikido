defmodule Aikido.Ownership.Actions.TrackChild do
  @moduledoc "Records a child's startup announcement and requests its process monitor."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    state = input.arguments.state
    data = input.arguments
    current = Map.get(state.children, data.tag)

    if data.parent_id == input.context.aikido.agent_id and is_pid(data.pid) and
         is_atom(data.child_module) and
         not match?(%{pid: pid} when pid == data.pid, current) do
      child =
        Aikido.Ownership.Child.new!(%{
          pid: data.pid,
          id: data.child_id,
          module: data.child_module,
          partition: Map.get(data, :child_partition),
          tag: data.tag,
          meta: data.meta
        })

      directives =
        Aikido.Ownership.Monitors.release(current) ++
          [%Aikido.Ownership.Directives.MonitorChild{tag: data.tag, pid: data.pid}]

      Aikido.Types.ActionResult.new(
        changes: %{children: Map.put(state.children, data.tag, child)},
        directives: directives
      )
    else
      Aikido.Types.ActionResult.new(changes: nil)
    end
  end
end
