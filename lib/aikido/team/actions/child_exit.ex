defmodule Aikido.Team.Actions.ChildExit do
  @moduledoc "Records a member exit, fails its active tasks and schedules reconciliation of its owned subtree."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{ActionAdapter, TaskDelivery, Topology}
  alias Aikido.Directives
  alias Aikido.Signal

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, _config} = ActionAdapter.unpack_team_action(input)
    data = Map.put(signal.data, :member, signal.data.tag)

    state
    |> record_member_exit(data, context)
    |> ActionAdapter.to_action_result()
  end

  defp record_member_exit(state, %{member: name, pid: pid} = data, context) do
    reason = Map.get(data, :result, Map.get(data, :reason))

    cond do
      Map.get(state.members, name) == pid ->
        affected = Topology.owned_members(state.topology, [name])

        state
        |> fail_affected_tasks(affected)
        |> remove_exited_member(name, pid, reason)
        |> request_subtree_recovery(state, name, affected, context)

      state.operation.status == :running and state.operation.awaiting == {:start, name} ->
        # Startup completion and process DOWN come from different senders. Retain
        # the exiting PID so a late completion cannot install an already-dead member.
        state
        |> record_startup_exit(name, pid, reason)
        |> then(&{:ok, &1, []})

      true ->
        {:ok, state, []}
    end
  end

  defp fail_affected_tasks(state, affected) do
    tasks =
      Map.new(state.tasks, fn {id, task} ->
        task =
          if task.member in affected and task.status == :dispatched,
            do: %{task | status: :failed, result: :member_exited},
            else: task

        {id, task}
      end)

    %{state | tasks: tasks}
  end

  defp remove_exited_member(state, name, pid, reason) do
    %{
      state
      | members: Map.delete(state.members, name),
        incarnations: Map.delete(state.incarnations, name),
        failures: Map.put(state.failures, name, %{pid: pid, reason: reason})
    }
  end

  defp record_startup_exit(state, name, pid, reason) do
    %{state | failures: Map.put(state.failures, name, %{pid: pid, reason: reason})}
  end

  defp request_subtree_recovery(state, previous, name, affected, context) do
    notifications = failed_task_notifications(state, previous, context)
    reconciliation = subtree_reconciliation(state, name, affected)
    {:ok, state, notifications ++ reconciliation}
  end

  defp failed_task_notifications(state, previous, context) do
    for {id, task} <- state.tasks,
        task.status == :failed and previous.tasks[id].status == :dispatched,
        directive <- TaskDelivery.task_result_delivery_directives(task, state, context),
        do: directive
  end

  defp subtree_reconciliation(state, name, affected) do
    if Map.has_key?(state.topology.nodes, name) and
         not Map.has_key?(state.paused, name) and state.operation.status != :running do
      # The owner may have died before forwarding its descendants' exits.
      # Stop retained descendant PIDs before rebuilding this owned subtree.
      [
        Directives.emit(%Signal{
          id: nil,
          type: "aikido.ash.team.reconcile",
          data: %{members: affected, replace: affected -- [name]},
          source: "/aikido"
        })
      ]
    else
      []
    end
  end
end
