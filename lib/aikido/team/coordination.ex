defmodule Aikido.Team.Coordination do
  @moduledoc "Projects adopted Team state into its finite requester-owned coordination contract."

  @doc "Build a coordination view from the current runtime without I/O."
  def project(runtime, requester) do
    team = runtime.agent.state.team

    Aikido.Team.Types.Coordination.new(
      coordinator: Aikido.Agent.Reference.from_runtime(runtime),
      requester: requester,
      members: member_views(team),
      tasks: task_views(team, requester)
    )
  end

  defp member_views(team) do
    Enum.map(team.topology.nodes, fn {name, _spec} ->
      %{
        name: name,
        running?: is_pid(team.members[name]),
        busy?:
          Enum.any?(team.tasks, fn {_id, task} ->
            task.member == name and task.status == :dispatched
          end)
      }
    end)
  end

  defp task_views(team, requester) do
    pending =
      Enum.map(team.pending_tasks, fn {id, task} ->
        task |> Map.put(:id, id) |> Map.put(:status, :pending)
      end)

    (Map.values(team.tasks) ++ pending)
    |> Enum.filter(fn task ->
      task[:requester] == requester or (requester == :self and is_nil(task[:requester]))
    end)
    |> Enum.map(fn task ->
      task
      |> Map.take([:id, :member, :requester, :notify, :status, :result])
      |> Map.put(:requester, if(is_nil(task[:requester]), do: :self, else: task[:requester]))
      |> Map.put(:metadata, Map.take(task[:metadata] || %{}, [:required_todo, :public]))
    end)
  end
end
