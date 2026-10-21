defmodule Aikido.Team.Actions.AssignTask do
  @moduledoc "Tracks a task and dispatches it to its member, activating a lazy member when needed."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.{Inputs, Tasks}
  alias Aikido.Directives
  alias Aikido.Signal

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = Inputs.unpack_team_action(input)
    Inputs.to_action_result(assign_or_activate_member(signal, state, context, config))
  end

  defp assign_or_activate_member(signal, state, context, config) do
    id = signal.data[:task_id] || signal.id

    cond do
      Map.has_key?(state.tasks, id) ->
        {:error, {:task_exists, id}}

      Map.has_key?(state.members, signal.data.member) ->
        state = Map.update(state, :pending_tasks, %{}, &Map.delete(&1, id))
        assign_task(signal, state, context)

      Map.has_key?(Map.get(state, :pending_tasks, %{}), id) ->
        {:error, :operation_in_progress}

      Map.has_key?(state.topology.nodes, signal.data.member) ->
        state =
          Map.update(state, :pending_tasks, %{id => signal.data}, &Map.put(&1, id, signal.data))

        Aikido.Team.Actions.EnsureMember.activate_member(
          %{signal | data: %{member: signal.data.member}},
          state,
          context,
          config
        )

      true ->
        {:error, {:unknown_member, signal.data.member}}
    end
  end

  defp assign_task(signal, state, context) do
    data = signal.data
    id = Map.get(data, :task_id) || signal.id

    with true <- !Map.has_key?(state.tasks, id) || {:error, {:task_exists, id}},
         {:ok, pid} <- Tasks.fetch_running_member_pid(state, data.member) do
      task = dispatched_task(id, data, state.incarnations[data.member])

      state
      |> Map.update!(:tasks, &Map.put(&1, id, task))
      |> request_task_execution(task, data, pid, context)
    end
  end

  defp dispatched_task(id, data, attempt) do
    %{
      id: id,
      member: data.member,
      status: :dispatched,
      result: nil,
      notify: data[:notify],
      metadata: data[:metadata] || %{},
      attempt: attempt
    }
  end

  defp request_task_execution(state, task, data, pid, context) do
    directives =
      task
      |> task_signal(data, context.agent_pid)
      |> Directives.emit_to_pid(pid)
      |> List.wrap()
      |> append_task_deadline(task, Map.get(data, :timeout_ms, 30_000))

    {:ok, state, directives}
  end

  defp task_signal(task, data, reply_to) do
    %Signal{
      id: nil,
      type: Map.get(data, :type, "harness.task"),
      data:
        Map.merge(Map.get(data, :payload, %{}), %{
          metadata: task.metadata,
          task_id: task.id,
          member: task.member,
          reply_to: reply_to,
          attempt: task.attempt
        }),
      source: "/ash/team"
    }
  end

  defp append_task_deadline(directives, task, timeout) when is_integer(timeout) and timeout > 0 do
    deadline =
      Directives.schedule(timeout, %Signal{
        id: nil,
        type: "aikido.ash.team.task.timeout",
        data: %{task_id: task.id, attempt: task.attempt},
        source: "/aikido"
      })

    directives ++ [deadline]
  end

  defp append_task_deadline(directives, _task, _timeout), do: directives
end
