defmodule Aikido.Team.TaskWorkerLifecycle do
  @moduledoc "Plans retirement of task-scoped workers once their owned subtree has no outstanding assignments."

  @doc "Request one eligible retirement; topology completion schedules the next one."
  def retirement_directives(%{operation: %{status: :running}}, _context), do: []

  def retirement_directives(state, context) do
    member =
      state.tasks
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.find_value(fn {_, task} ->
        if eligible?(state, task.member), do: task.member
      end)

    if member do
      [
        Aikido.Directives.emit_to_pid(
          %Aikido.Signal{
            id: nil,
            type: "aikido.ash.team.retire_worker",
            data: %{member: member},
            source: "/aikido"
          },
          context.agent_pid
        )
      ]
    else
      []
    end
  end

  @doc "Recheck the current incarnation and all owned assignments before stopping a worker."
  def eligible?(state, member) do
    members = Aikido.Team.Topology.owned_members(state.topology, [member])

    Map.has_key?(state.members, member) && !Map.get(state.paused, member, false) &&
      Enum.any?(state.tasks, fn {_, task} ->
        task.member == member && task.status in [:completed, :failed] &&
          Map.get(task, :worker_lifecycle, :keep) == :stop &&
          task.attempt == state.incarnations[member]
      end) &&
      !Enum.any?(state.tasks, fn {_, task} ->
        task.member in members && task.status == :dispatched
      end) &&
      !Enum.any?(state.pending_tasks, fn {_, task} -> task.member in members end)
  end
end
