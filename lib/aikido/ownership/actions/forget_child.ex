defmodule Aikido.Ownership.Actions.ForgetChild do
  @moduledoc "Removes the exited child and forwards its exit to the coordinating team."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _) do
    state = input.arguments.state
    %{tag: tag, pid: pid} = input.arguments
    ref = Map.get(input.arguments, :monitor_ref)

    case Map.get(state.children, tag) do
      %{pid: ^pid} = child when is_nil(ref) or is_nil(child.ref) or child.ref == ref ->
        directives =
          Aikido.Ownership.Monitors.release(child) ++ notify_team(child, input.context.aikido)

        Aikido.Types.ActionResult.new(
          changes: %{children: Map.delete(state.children, tag)},
          directives: directives
        )

      _ ->
        Aikido.Types.ActionResult.new(changes: nil)
    end
  end

  defp notify_team(child, runtime) do
    case child.meta[:team_pid] do
      pid when is_pid(pid) and pid != runtime.agent_pid ->
        if match?(
             %{protocol: Aikido.Ownership.Delivery, kind: :process_exit},
             runtime[:__delivery__]
           ) do
          reference =
            Aikido.Agent.Reference.new!(
              id: child.meta.team_id,
              resource: child.meta.team_resource,
              aikido: runtime.aikido,
              partition: runtime.partition
            )

          [
            Aikido.Team.Directives.Deliver.new!(
              target: pid,
              signal: runtime.signal,
              signal_type: runtime.signal.type,
              kind: :owned_child_exit,
              recipient: reference
            )
          ]
        else
          []
        end

      _ ->
        []
    end
  end
end
