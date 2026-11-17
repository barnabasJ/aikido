defmodule Aikido.Team.Actions.AssignTask do
  @moduledoc "Tracks a task and dispatches it to its member, activating a lazy member when needed."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.ActionAdapter
  alias Aikido.Team.TaskDelivery
  alias Aikido.Directives
  alias Aikido.Signal

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, config} = ActionAdapter.unpack_team_action(input)

    signal = restore_pending_assignment(signal, state)

    with :ok <- Aikido.Team.TaskDependencies.validate_assignment(state, signal.data) do
      ActionAdapter.to_action_result(
        assign_or_activate_member(signal, state, context, config),
        state,
        context
      )
    end
  end

  defp restore_pending_assignment(signal, state) do
    id = signal.data[:task_id] || signal.id
    pending = Map.get(Map.get(state, :pending_tasks, %{}), id, %{})

    binding =
      Map.take(pending, [:mode, :notify, :requester, :recipient_request_id, :recipient_active?])

    data =
      signal.data |> Map.drop([:recipient_request_id, :recipient_active?]) |> Map.merge(binding)

    %{signal | data: data}
  end

  defp assign_or_activate_member(signal, state, context, config) do
    id = signal.data[:task_id] || signal.id

    cond do
      Map.has_key?(state.tasks, id) ->
        task_exists(id)

      Map.has_key?(state.members, signal.data.member) ->
        assign_task(signal, state, context)

      Map.has_key?(Map.get(state, :pending_tasks, %{}), id) ->
        {:error,
         Ash.Error.Action.InvalidArgument.exception(
           field: :task_id,
           message:
             "Task #{inspect(id)} is already awaiting member activation. " <>
               "Wait for its existing assignment instead of submitting it again."
         )}

      Map.has_key?(state.topology.nodes, signal.data.member) ->
        data = Map.merge(signal.data, TaskDelivery.capture_recipient_run(signal.data, context))
        state = Map.update(state, :pending_tasks, %{id => data}, &Map.put(&1, id, data))

        Aikido.Team.Actions.EnsureMember.activate_member(
          %{signal | data: %{member: signal.data.member}},
          state,
          context,
          config
        )

      true ->
        {:error,
         Ash.Error.Action.InvalidArgument.exception(
           field: :member,
           message:
             "Unknown team member #{inspect(signal.data.member)}. " <>
               "Inspect the roster or add the member before assigning work."
         )}
    end
  end

  defp assign_task(signal, state, context) do
    data = signal.data
    id = Map.get(data, :task_id) || signal.id

    with true <- !Map.has_key?(state.tasks, id) || task_exists(id),
         {:ok, pid} <- Aikido.Team.MemberProcesses.fetch_running_member_pid(state, data.member) do
      pending = Map.get(state, :pending_tasks, %{})

      data =
        if Map.has_key?(pending, id),
          do: data,
          else: Map.merge(data, TaskDelivery.capture_recipient_run(data, context))

      task =
        dispatched_task(id, data, state.incarnations[data.member])
        |> TaskDelivery.bind_saved_recipient_run(data)

      state
      |> Map.put(:pending_tasks, Map.delete(pending, id))
      |> Map.update!(:tasks, &Map.put(&1, id, task))
      |> request_task_execution(task, data, pid, context)
    end
  end

  defp task_exists(id) do
    {:error,
     Ash.Error.Action.InvalidArgument.exception(
       field: :task_id,
       message:
         "Task #{inspect(id)} already exists. Inspect its result or background the existing " <>
           "task; use a new task ID only for a distinct assignment."
     )}
  end

  defp dispatched_task(id, data, attempt) do
    %{
      id: id,
      member: data.member,
      status: :dispatched,
      result: nil,
      notify: Aikido.Team.TaskDelivery.notification_recipient(data),
      requester: data[:requester],
      mode: Map.get(data, :mode, :background),
      worker_lifecycle: Map.get(data, :worker_lifecycle, :keep),
      metadata: data[:metadata] || %{},
      attempt: attempt
    }
  end

  defp request_task_execution(state, task, data, pid, context) do
    directives =
      task
      |> task_signal(data, context.agent_pid)
      |> Aikido.Team.Delivery.directive(pid, :task, context)
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
