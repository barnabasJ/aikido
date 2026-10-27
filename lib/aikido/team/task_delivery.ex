defmodule Aikido.Team.TaskDelivery do
  @moduledoc """
  Builds conversation-message descriptors for finished team tasks.

  Resolves each task’s configured notification recipient and describes the text
  and correlation metadata to deliver. These functions perform no delivery I/O;
  the returned directives send the messages after state adoption.
  """
  alias Aikido.Directives
  alias Aikido.Signal

  @doc "Build delivery directives for the task's configured notification recipient."
  def task_result_delivery_directives(task, state, context) do
    case task_result_recipient_pid(task, state, context) do
      nil -> []
      pid -> [Directives.emit_to_pid(conversation_message_for_task_result(task), pid)]
    end
  end

  @doc "Resolve the current recipient PID, or nil when the task has no live recipient."
  def task_result_recipient_pid(task, state, context) do
    case Map.get(task, :notify) do
      :self -> context.agent_pid
      nil -> nil
      member -> state.members[member]
    end
  end

  @doc "Describe text to add to the receiving AI agent’s conversation when a task finishes."
  def conversation_message_for_task_result(task) do
    text =
      "Task #{task.id} from #{task.member} #{task.status}: " <>
        describe_task_result(task)

    %Signal{
      id: nil,
      type: "ai.react.deliver",
      data: %{
        text: text,
        request_id: "task-result/" <> task.id,
        metadata:
          (Map.get(task, :metadata) || %{})
          |> Map.take([:aikido_deadline_at])
          |> Map.put(:task, Map.take(task, [:id, :member, :status, :result, :metadata]))
      },
      source: "/aikido"
    }
  end

  defp describe_task_result(%{status: :failed, result: :timeout}) do
    "The task's remaining deadline expired and cancellation was requested. Report partial " <>
      "findings or request a new run with a smaller assignment or larger budget; do not retry with the expired deadline."
  end

  defp describe_task_result(%{status: :failed, result: :member_exited}) do
    "The worker process exited before its result was recorded. Inspect the roster and lifecycle " <>
      "failure, ensure a replacement is ready, and check completed effects before assigning the work again."
  end

  defp describe_task_result(%{status: :failed, result: :interrupted}) do
    "Recovery interrupted this in-flight assignment; its running work was not resumed. Inspect " <>
      "saved results and completed effects before starting a new assignment with a fresh deadline."
  end

  defp describe_task_result(%{status: :failed, result: :cancelled}) do
    "The assignment was cancelled. Do not retry automatically; wait for a new assignment and " <>
      "check whether earlier effects completed."
  end

  defp describe_task_result(%{status: :failed, result: error}) when is_exception(error) do
    if AshAi.ToToolError.impl_for(error) do
      AshAi.ToToolError.to_tool_error(error)
    else
      "Worker failed with #{inspect(error.__struct__)}. Inspect the worker's state and " <>
        "runtime logs before retrying; its effects may be incomplete."
    end
  end

  defp describe_task_result(%{status: :failed, result: error}) do
    inspect(error, limit: 100, printable_limit: 4_000) <>
      ". Inspect the task and worker state, correct the reported cause, and check completed effects before retrying."
  end

  defp describe_task_result(task),
    do: inspect(task.result, limit: 100, printable_limit: 4_000)
end
