defmodule Aikido.Team.Tasks do
  @moduledoc "Pure task notification construction and live member lookup."
  alias Aikido.Directives
  alias Aikido.Signal

  def notify(task, state, context) do
    pid =
      case Map.get(task, :notify) do
        :self -> context.agent_pid
        nil -> nil
        member -> state.members[member]
      end

    if pid do
      text =
        "Task #{task.id} from #{task.member} #{task.status}: " <>
          inspect(task.result, limit: 100, printable_limit: 4_000)

      signal =
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

      [Directives.emit_to_pid(signal, pid)]
    else
      []
    end
  end

  def fetch_member(state, name) do
    case Map.fetch(state.members, name) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, {:member_not_running, name}}
    end
  end
end
