defmodule Aikido.Team.Delivery do
  @moduledoc "Validates team delivery correlation before applying an authenticated recipient identity."

  alias Aikido.Team.Directives.Deliver

  @doc "Describe recipient-owned delivery for bound activations; retain caller delivery otherwise."
  def directive(signal, target, kind, context, options \\ []) do
    if is_nil(context[:execution_scope]) do
      Aikido.Directives.emit_to_pid(signal, target)
    else
      Deliver.new!(
        Keyword.merge(
          [signal: signal, target: target, kind: kind, signal_type: signal.type],
          options
        )
      )
    end
  end

  def permitted?(runtime, sender, signal, %{kind: :task, signal_type: type}) do
    signal.type == type && coordinator?(runtime, sender) && signal.data[:reply_to] == sender.pid
  end

  def permitted?(runtime, sender, signal, %{kind: :completion}) do
    team = runtime.agent.state[:team]
    data = signal.data

    case team && team.tasks[data.task_id] do
      %{status: :dispatched, member: member, attempt: attempt} ->
        signal.type in ["aikido.ash.team.task.completed", "aikido.ash.team.task.failed"] &&
          sender.aikido == runtime.aikido && sender.partition == runtime.partition &&
          team.members[member] == sender.pid &&
          member == data.member && attempt == data.attempt

      _ ->
        false
    end
  end

  def permitted?(runtime, sender, signal, %{kind: :result} = delivery) do
    ai = runtime.agent.state[:ai]

    signal.type == "ai.react.deliver" && coordinator?(runtime, sender) && ai &&
      ai.request_id == delivery.request_id &&
      (!delivery.active? || ai.status in [:setup, :running, :waiting]) &&
      !Enum.any?(ai.run_metadata[:deliveries] || [], &(&1[:request_id] == signal.data.request_id))
  end

  def permitted?(runtime, sender, signal, %{kind: :cancel}) do
    work =
      Enum.find_value(runtime.agent.state, fn
        {_path, %Aikido.AiWorker.Slice{} = work} -> work
        _ -> nil
      end)

    signal.type == "harness.cancel_task" && coordinator?(runtime, sender) && work &&
      ((work.pending && work.pending.task_id == signal.data.task_id) ||
         Enum.any?(work.queue, &(&1.task_id == signal.data.task_id)))
  end

  def permitted?(runtime, sender, signal, %{kind: :message, signal_type: type}),
    do: signal.type == type && coordinator?(runtime, sender)

  def permitted?(_runtime, _sender, _signal, _delivery), do: false

  defp coordinator?(runtime, sender) do
    parent = Aikido.Ownership.parent(runtime)

    sender.aikido == runtime.aikido && sender.partition == runtime.partition &&
      ((sender.id == runtime.id && sender.pid == self()) ||
         (parent && sender.id == parent.meta[:team_id] && sender.pid == parent.meta[:team_pid]))
  end
end
