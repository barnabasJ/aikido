defmodule Aikido.Team.Tasks do
  @moduledoc "Pure task notification construction and live member lookup."
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
        inspect(task.result, limit: 100, printable_limit: 4_000)

    %Signal{
      id: nil,
      type: "ai.react.deliver",
      data: %{
        text: text,
        request_id: "task-result/" <> task.id,
        metadata: %{task: Map.take(task, [:id, :member, :status, :result, :metadata])}
      },
      source: "/aikido"
    }
  end

  def fetch_running_member_pid(state, name) do
    case Map.fetch(state.members, name) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, {:member_not_running, name}}
    end
  end
end
