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

  @doc "Require runtime-owned transport before public owning-resource admission."
  def admit(%{type: "aikido.agent.inherit"}, context),
    do: admit_inheritance(context, :inheritance)

  def admit(%{type: "aikido.ash.team.inherited"}, context),
    do: admit_inheritance(context, :inheritance_result)

  def admit(_signal, _context), do: :ok

  @doc "Describe one acknowledgement after all receiving state and middleware changes are adopted."
  def inheritance_result(target, operation_id, member, error \\ nil) do
    signal = %Aikido.Signal{
      type: "aikido.ash.team.inherited",
      data: %{operation_id: operation_id, member: member, error: error}
    }

    Deliver.new!(
      signal: signal,
      target: target,
      kind: :inheritance_result,
      signal_type: signal.type
    )
  end

  @doc "Report a rejected verified request without exposing receiving state or private errors."
  def reject_inheritance(runtime, sender, request, error) do
    signal =
      Aikido.Team.Signals.Inherited.new!(%{
        operation_id: request.data.operation_id,
        member: request.data.member,
        error: inheritance_error(error)
      })

    Aikido.Signal.Delivery.send(__MODULE__, sender.pid, signal, runtime, %{
      kind: :inheritance_result,
      signal_type: signal.type
    })
  end

  defp admit_inheritance(context, kind) do
    case context[:__delivery__] do
      %{protocol: __MODULE__, kind: ^kind} ->
        :ok

      _ ->
        {:error, Ash.Error.to_error_class(Aikido.Team.Errors.UntrustedInheritance.exception([]))}
    end
  end

  defp inheritance_error(%Ash.Error.Forbidden{}),
    do:
      "The receiving agent did not authorize inherited configuration. Restore its own execution permission before reconciling again; no inherited changes were adopted."

  defp inheritance_error(%Ash.Error.Invalid{}),
    do:
      "The receiving agent rejected inherited configuration. Check its writable own-state attributes, constraints and active team operation before reconciling again."

  defp inheritance_error(_error),
    do:
      "The receiving agent could not adopt inherited configuration. Inspect its runtime errors before reconciling again; no acknowledgement of adoption is implied."

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

  def permitted?(
        runtime,
        sender,
        %{type: "aikido.agent.inherit", data: %{operation_id: _, member: member, changes: %{}}},
        %{
          kind: :inheritance,
          signal_type: "aikido.agent.inherit"
        }
      ) do
    parent = Aikido.Ownership.parent(runtime)

    parent && sender.aikido == runtime.aikido && sender.partition == runtime.partition &&
      parent.meta[:team_id] == sender.id && parent.meta[:team_pid] == sender.pid &&
      parent.meta[:team_resource] == sender.resource && parent.meta[:member] == member
  end

  def permitted?(
        runtime,
        sender,
        %{type: "aikido.ash.team.inherited", data: %{operation_id: operation_id, member: member}},
        %{
          kind: :inheritance_result,
          signal_type: "aikido.ash.team.inherited"
        }
      ) do
    team = runtime.agent.state[:team]

    team && Aikido.Team.TopologyOperation.awaited?(team, operation_id, {:inherit, member}) &&
      sender.aikido == runtime.aikido && sender.partition == runtime.partition &&
      team.members[member] == sender.pid && team.topology.nodes[member] &&
      team.topology.nodes[member].resource == sender.resource &&
      Aikido.Team.Topology.member_id(team.topology, runtime.id, member) == sender.id
  end

  def permitted?(_runtime, _sender, _signal, _delivery), do: false

  defp coordinator?(runtime, sender) do
    parent = Aikido.Ownership.parent(runtime)

    sender.aikido == runtime.aikido && sender.partition == runtime.partition &&
      ((sender.id == runtime.id && sender.pid == self()) ||
         (parent && sender.id == parent.meta[:team_id] && sender.pid == parent.meta[:team_pid]))
  end
end
