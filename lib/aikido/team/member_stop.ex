defmodule Aikido.Team.MemberStop do
  @moduledoc "Tracks receiver-prepared cleanup and the matching monitored exit for one member stop."

  alias Aikido.Team.TopologyOperation

  @doc "Capture stop addresses before the proposed topology removes their declarations."
  def targets(state, names, context, config) do
    for name <- names, pid = state.members[name], is_pid(pid), into: %{} do
      reference =
        Aikido.Agent.Reference.new!(
          id: Aikido.Team.Topology.member_id(state.topology, context.agent_id, name),
          resource: state.topology.nodes[name].resource,
          aikido: config.instance,
          partition: context.partition
        )

      owner = state.topology.nodes[name].owner

      owner_reference =
        if owner,
          do:
            Aikido.Agent.Reference.new!(
              id: Aikido.Team.Topology.member_id(state.topology, context.agent_id, owner),
              resource: state.topology.nodes[owner].resource,
              aikido: config.instance,
              partition: context.partition
            )

      {name,
       %{
         pid: pid,
         reference: reference,
         owner_reference: owner_reference,
         owner_pid: if(owner, do: state.members[owner], else: context.agent_pid),
         orphaned?: missing_owner_ancestor?(state, name)
       }}
    end
  end

  @doc "Whether a declared ownership ancestor is absent from the adopted membership snapshot."
  def missing_owner_ancestor?(%{topology: %{nodes: nodes}, members: members}, name)
      when is_map(nodes) and is_map(members) do
    missing_owner_ancestor?(nodes, members, name, MapSet.new(), false)
  end

  def missing_owner_ancestor?(_state, _name), do: false

  defp missing_owner_ancestor?(nodes, members, name, visited, missing?) do
    if MapSet.member?(visited, name) do
      false
    else
      case Map.fetch(nodes, name) do
        {:ok, %{owner: nil}} ->
          missing?

        {:ok, %{owner: owner}} ->
          missing_owner_ancestor?(
            nodes,
            members,
            owner,
            MapSet.put(visited, name),
            missing? or not Map.has_key?(members, owner)
          )

        _malformed_or_undeclared ->
          false
      end
    end
  end

  @doc "Describe one receiver-owned stop and retain its exact target until preparation and exit agree."
  def request(state, name, pid) do
    target = Map.fetch!(state.operation.stop_targets, name)

    stop =
      Map.merge(target, %{
        member: name,
        prepared?: false,
        exit: nil,
        monitor_ref: nil,
        requested?: false
      })

    operation = state.operation |> Map.put(:stop, stop) |> Map.put(:awaiting, {:stop, name})

    effect =
      Aikido.Team.Directives.MonitorStop.new!(
        target: pid,
        member: name,
        operation_id: state.operation.id
      )

    {:ok, %{state | operation: operation}, [effect]}
  end

  @doc "Record late cleanup intent through native owner adoption before describing its effect."
  def cleanup(state, %{reference: reference, result: pid, member: name, operation_id: id}) do
    failure = %{
      pid: pid,
      reference: reference,
      operation_id: id,
      reason: {:late_activation_cleanup, :pending}
    }

    if state.failures[name] == failure do
      {:ok, state, []}
    else
      state = %{state | failures: Map.put(state.failures, name, failure)}
      {:ok, state, [directive(reference, pid, name, id, :stop_cleanup)]}
    end
  end

  @doc "Adopt a native monitor result and request cleanup only after the monitor is installed."
  def monitored(data, state, context, config) do
    if awaiting?(state, data.member, data.pid) && data.operation_id == state.operation.id do
      state = put_in(state.operation.stop.monitor_ref, data.ref)
      settle_or_request(state, context, config)
    else
      {:ok, state, Aikido.Ownership.Monitors.release(%{ref: data.ref})}
    end
  end

  defp settle_or_request(state, context, config) do
    stop = state.operation.stop

    if stop.exit do
      settle(state, context, config)
    else
      state = put_in(state.operation.stop.requested?, true)
      effect = directive(stop.reference, stop.pid, stop.member, state.operation.id, :stop)
      {:ok, state, [effect]}
    end
  end

  @doc "Retain receiving cleanup results for the exact pending late incarnation."
  def cleanup_result(data, state) do
    case state.failures[data.member] do
      %{pid: pid, operation_id: id} = failure when pid == data.pid and id == data.operation_id ->
        # The result signal retains native errors; saved failure facts retain only the outcome.
        outcome = if is_nil(data.reason), do: :prepared, else: :failed
        failure = %{failure | reason: {:late_activation_cleanup, outcome}}
        {:ok, %{state | failures: Map.put(state.failures, data.member, failure)}, []}

      _ ->
        {:ok, state, []}
    end
  end

  defp directive(reference, pid, member, operation_id, kind) do
    Aikido.Team.Directives.Deliver.new!(
      signal: %Aikido.Signal{type: "aikido.agent.lifecycle.stopping", data: %{reason: :normal}},
      target: pid,
      kind: kind,
      signal_type: "aikido.agent.lifecycle.stopping",
      recipient: reference,
      member: member,
      operation_id: operation_id
    )
  end

  @doc "Whether this operation owns the exact incarnation being stopped."
  def awaiting?(state, member, pid) do
    TopologyOperation.awaited?(state, state.operation.id, {:stop, member}) &&
      match?(%{member: ^member, pid: ^pid}, state.operation[:stop])
  end

  @doc "Record successful receiving cleanup; acknowledgement alone does not imply process exit."
  def prepared(data, state, context, config) do
    if awaiting?(state, data.member, data.pid) && data.operation_id == state.operation.id &&
         data.result == :prepared do
      state = put_in(state.operation.stop.prepared?, true)
      settle(state, context, config)
    else
      {:ok, state, []}
    end
  end

  @doc "Record an actual monitor exit, rejecting an ordinary typed signal as proof of death."
  def exited(data, state, context, config) do
    if match?(%{protocol: Aikido.Team.Delivery, kind: :process_exit}, context[:__delivery__]) do
      state = %{
        state
        | members: Map.delete(state.members, data.member),
          incarnations: Map.delete(state.incarnations, data.member)
      }

      state = put_in(state.operation.stop.exit, %{reason: data.reason, ref: data.monitor_ref})
      settle(state, context, config)
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  defp settle(%{operation: %{stop: %{exit: nil}}} = state, _context, _config),
    do: {:ok, state, []}

  defp settle(%{operation: %{stop: %{monitor_ref: nil}}} = state, _context, _config),
    do: {:ok, state, []}

  defp settle(state, context, config) do
    stop = state.operation.stop

    cond do
      stop.exit.ref != stop.monitor_ref ->
        {:error, Ash.Error.Forbidden.exception([])}

      stop.exit.reason == :noproc || stop.orphaned? ->
        complete(state, context, config, :observed_absent)

      !clean_exit?(stop.exit.reason) ->
        TopologyOperation.fail_operation_and_pending_tasks(
          %{
            operation_id: state.operation.id,
            reason: {:member_stop_failed, stop.member, {:unexpected_exit, stop.exit.reason}}
          },
          state,
          context
        )

      stop.prepared? ->
        complete(state, context, config)

      true ->
        {:ok, state, []}
    end
  end

  defp complete(state, context, config, field \\ :stopped) do
    stop = state.operation.stop

    operation =
      state.operation
      |> Map.delete(:stop)
      |> Map.update(field, [stop.member], &(&1 ++ [stop.member]))

    TopologyOperation.advance_member_lifecycle(%{state | operation: operation}, context, config)
  end

  @doc "Release the exact monitor of a failed or timed-out stop step."
  def release_monitor(state) do
    Aikido.Ownership.Monitors.release(%{ref: get_in(state.operation, [:stop, :monitor_ref])})
  end

  defp clean_exit?(:normal), do: true
  defp clean_exit?(:shutdown), do: true
  defp clean_exit?({:shutdown, _}), do: true
  defp clean_exit?(_reason), do: false
end
