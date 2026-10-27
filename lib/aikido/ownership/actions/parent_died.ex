defmodule Aikido.Ownership.Actions.ParentDied do
  @moduledoc "Applies the parent-death policy and emits orphan notifications when requested."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    state = input.arguments.state
    former_parent = input.arguments.former_parent

    if state.parent == former_parent and
         (is_nil(state.parent_monitor) or
            state.parent_monitor == Map.get(input.arguments, :monitor_ref)) do
      apply_parent_death_policy(
        state,
        former_parent,
        input.arguments.reason,
        input.context.aikido
      )
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp apply_parent_death_policy(%{on_parent_death: :stop} = state, _, reason, _) do
    Aikido.Types.ActionResult.new(
      state: state,
      directives: [%Aikido.Directives.Stop{reason: {:shutdown, {:parent_down, reason}}}]
    )
  end

  defp apply_parent_death_policy(state, former_parent, reason, context) do
    directives =
      if state.on_parent_death == :emit_orphan,
        do: orphan_notifications(former_parent, reason, context.agent_pid),
        else: []

    Aikido.Types.ActionResult.new(
      state: %{state | parent: nil, orphaned_from: former_parent, parent_monitor: nil},
      directives: Aikido.Ownership.Monitors.release(%{ref: state.parent_monitor}) ++ directives
    )
  end

  defp orphan_notifications(parent, reason, target) do
    [
      %Aikido.Directives.Emit{
        target: target,
        signal: %Aikido.Signal{
          type: "aikido.agent.identity.orphaned",
          data: %{former_parent: parent, reason: reason}
        }
      },
      %Aikido.Directives.Emit{
        target: target,
        signal: %Aikido.Signal{
          type: "aikido.agent.orphaned",
          data: %{
            parent_id: parent.id,
            parent_pid: parent.pid,
            tag: parent.tag,
            meta: parent.meta || %{},
            reason: reason
          }
        }
      }
    ]
  end
end
