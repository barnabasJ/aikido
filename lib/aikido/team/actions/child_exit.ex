defmodule Aikido.Team.Actions.ChildExit do
  @moduledoc "Records a member exit, fails its active tasks and schedules reconciliation of its owned subtree."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Tasks, Topology}
  alias Aikido.Directives
  alias Aikido.Signal

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.read(input)
    Inputs.result(reduce(Map.put(signal.data, :member, signal.data.tag), state, context, config))
  end

  defp reduce(%{member: name, pid: pid} = data, state, context, _config) do
    reason = Map.get(data, :result, Map.get(data, :reason))

    cond do
      Map.get(state.members, name) == pid ->
        affected = Topology.owned_members(state.topology, [name])
        previous = state

        tasks =
          Map.new(state.tasks, fn {id, task} ->
            {id,
             if(task.member in affected and task.status == :dispatched,
               do: %{task | status: :failed, result: :member_exited},
               else: task
             )}
          end)

        state = %{
          state
          | members: Map.delete(state.members, name),
            incarnations: Map.delete(state.incarnations, name),
            failures: Map.put(state.failures, name, %{pid: pid, reason: reason}),
            tasks: tasks
        }

        notifications =
          for {id, task} <- tasks,
              task.status == :failed and previous.tasks[id].status == :dispatched,
              effect <- Tasks.notify(task, state, context),
              do: effect

        # The owner may have died before it could forward its descendants' exits.
        # Stop retained descendant PIDs before rebuilding this owned subtree.
        reconcile =
          if Map.has_key?(state.topology.nodes, name) and
               not Map.has_key?(state.paused, name) and state.operation.status != :running do
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

        {:ok, state, notifications ++ reconcile}

      state.operation.status == :running and state.operation.awaiting == {:start, name} ->
        # Startup completion and process DOWN come from different senders. Retain
        # the exiting PID so a late completion cannot install an already-dead member.
        {:ok, %{state | failures: Map.put(state.failures, name, %{pid: pid, reason: reason})}, []}

      true ->
        {:ok, state, []}
    end
  end
end
