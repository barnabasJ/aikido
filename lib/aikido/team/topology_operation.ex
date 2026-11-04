defmodule Aikido.Team.TopologyOperation do
  @moduledoc """
  Plans and tracks one team topology change through member start/stop signals.

  Validates worker limits, orders member changes and records the currently
  awaited step. Member exits and operation failures also settle affected tasks.
  Returned directives request process effects; this module performs no I/O.
  """
  alias Aikido.Team.{TaskDelivery, Topology}
  alias Aikido.Directives
  alias Aikido.Signal

  def begin_topology_change(
        signal,
        %{operation: %{status: :running}} = state,
        _context,
        _config,
        _plan
      ) do
    {:ok, Map.update(state, :queued_operations, [signal], &(&1 ++ [signal])), []}
  end

  def begin_topology_change(signal, state, context, config, plan) do
    with {:ok, topology, stop, requested, paused} <- plan.(),
         :ok <- validate_worker_limits(topology, config),
         {:ok, steps} <- order_member_steps(state.topology, topology, stop, requested) do
      steps = include_inheritance_steps(steps, config)
      stop_targets = Aikido.Team.MemberStop.targets(state, stop, context, config)

      state
      |> adopt_topology(topology, paused)
      |> begin_operation(signal.id, steps)
      |> put_in([Access.key(:operation), :stop_targets], stop_targets)
      |> advance_member_lifecycle(context, config)
      |> append_operation_deadline(signal.id, config.timeout)
    else
      {:error, reason} ->
        operation = %{state.operation | id: signal.id, status: :failed, error: reason}
        {state, directives} = release_queued_operations(%{state | operation: operation}, context)
        {:ok, state, directives}
    end
  end

  @doc "Track opt-in inherited changes across currently running members and nested teams."
  def reconcile_inherited(signal, state, context, config, reply \\ nil)

  def reconcile_inherited(
        signal,
        %{operation: %{status: :running}} = state,
        _context,
        _config,
        nil
      ) do
    {:ok, Map.update(state, :queued_operations, [signal], &(&1 ++ [signal])), []}
  end

  def reconcile_inherited(_signal, %{operation: %{status: :running}}, _context, _config, _reply) do
    {:error,
     Ash.Error.Action.InvalidArgument.exception(
       field: :state,
       message:
         "The receiving team's topology operation is busy. Await its completion before reconciling inherited configuration."
     )}
  end

  def reconcile_inherited(signal, state, context, config, reply) do
    names = for {name, pid} <- state.members, is_pid(pid), do: name

    with {:ok, ordered} <- Topology.order(state.topology.nodes, names) do
      steps =
        if Map.get(config, :reconcile_inherit, []) == [],
          do: [],
          else: Enum.map(ordered, &{:inherit, &1})

      state
      |> begin_operation(signal.id, steps)
      |> put_inheritance_reply(reply)
      |> advance_member_lifecycle(context, config)
      |> append_operation_deadline(signal.id, config.timeout)
    end
  end

  defp include_inheritance_steps(steps, config) do
    if Map.get(config, :reconcile_inherit, []) == [] do
      steps
    else
      Enum.flat_map(steps, fn
        {:start, name} = start -> [start, {:inherit, name}]
        step -> [step]
      end)
    end
  end

  defp put_inheritance_reply(state, nil), do: state

  defp put_inheritance_reply(state, reply),
    do: put_in(state.operation, Map.put(state.operation, :inheritance_reply, reply))

  @doc "Release scoped topology commands after the current lifecycle operation settles."
  def release_queued_operations(state, context) do
    case Map.get(state, :queued_operations, []) do
      [_ | _] = signals ->
        {Map.put(state, :queued_operations, []),
         Enum.map(
           signals,
           &%Aikido.Directives.Emit{signal: &1, target: context.agent_pid, inherit_scope?: false}
         )}

      [] ->
        {state, Aikido.Team.TaskWorkerLifecycle.retirement_directives(state, context)}
    end
  end

  @doc "Order dependent member stops before starts for a proposed topology."
  def order_member_steps(current, desired, stop, requested) do
    with {:ok, stops} <- Topology.order(current.nodes, stop),
         {:ok, starts} <-
           Topology.order(desired.nodes, Topology.members_with_prerequisites(desired, requested)) do
      {:ok, Enum.map(Enum.reverse(stops), &{:stop, &1}) ++ Enum.map(starts, &{:start, &1})}
    end
  end

  defp adopt_topology(state, topology, paused) do
    version =
      if topology.nodes == state.topology.nodes,
        do: state.topology.version,
        else: state.topology.version + 1

    %{state | topology: %{topology | version: version}, paused: paused}
  end

  defp begin_operation(state, id, steps) do
    operation = %{
      id: id,
      status: :running,
      remaining: steps,
      awaiting: nil,
      started: [],
      stopped: [],
      error: nil
    }

    %{state | operation: operation}
  end

  defp append_operation_deadline({:ok, state, directives}, id, timeout) do
    timer =
      Directives.schedule(timeout, %Signal{
        id: nil,
        type: "aikido.ash.team.timeout",
        data: %{operation_id: id},
        source: "/aikido"
      })

    {:ok, state, directives ++ [timer]}
  end

  @doc "Check worker template counts and resource identities in a proposed topology."
  def validate_worker_limits(topology, config) do
    counts = Enum.frequencies_by(Map.values(topology.nodes), & &1.template)

    Enum.reduce_while(counts, :ok, fn
      {nil, _}, :ok ->
        {:cont, :ok}

      {template, count}, :ok ->
        case config.workers[template] do
          %{max_members: maximum, resource: resource} when count <= maximum ->
            if template_resources_match?(topology.nodes, template, resource),
              do: {:cont, :ok},
              else: {:halt, {:error, {:template_resource_mismatch, template}}}

          _ ->
            {:halt, {:error, {:worker_limit, template}}}
        end
    end)
  end

  defp template_resources_match?(nodes, template, resource) do
    Enum.all?(nodes, fn {_, spec} ->
      spec.template != template || spec.resource == resource
    end)
  end

  def advance_member_lifecycle(%{operation: %{remaining: []}} = state, context, _config) do
    state = put_in(state.operation.status, :completed)

    completed =
      %Signal{
        id: nil,
        type: "aikido.ash.team.operation.completed",
        data: %{operation_id: state.operation.id},
        source: "/aikido"
      }

    directives =
      [Directives.emit_to_pid(completed, context.agent_pid)] ++
        pending_task_assignments(state) ++ recovered_task_notifications(state, context)

    {state, inherited} = settle_inheritance_reply(state, nil)
    {:ok, Map.put(state, :recovered_tasks, []), directives ++ inherited}
  end

  def advance_member_lifecycle(
        %{operation: %{remaining: [{kind, name} | rest]}} = state,
        context,
        config
      ) do
    state = put_in(state.operation.remaining, rest)

    case {kind, Map.get(state.members, name)} do
      {:stop, nil} ->
        advance_member_lifecycle(state, context, config)

      {:start, pid} when is_pid(pid) ->
        advance_member_lifecycle(state, context, config)

      {:stop, pid} ->
        Aikido.Team.MemberStop.request(state, name, pid)

      {:start, nil} ->
        request_member_start(state, name, context, config)

      {:inherit, pid} when is_pid(pid) ->
        request_member_inheritance(state, name, pid, context, config)

      {:inherit, nil} ->
        fail_operation_and_pending_tasks(
          %{operation_id: state.operation.id, reason: {:member_not_running, name}},
          state,
          context
        )
    end
  end

  defp pending_task_assignments(state) do
    Enum.map(Map.get(state, :pending_tasks, %{}), fn {id, data} ->
      Directives.emit(%Signal{
        id: nil,
        type: "aikido.ash.team.assign_task",
        data: Map.put(data, :task_id, id),
        source: "/aikido"
      })
    end)
  end

  defp recovered_task_notifications(state, context) do
    Enum.flat_map(Map.get(state, :recovered_tasks, []), fn id ->
      TaskDelivery.task_result_delivery_directives(state.tasks[id], state, context)
    end)
  end

  defp request_member_start(state, name, context, config) do
    spec = state.topology.nodes[name]
    parent = member_parent(state, name, spec.owner, context, config)
    initial = inherited_member_state(spec, context, config)

    effect =
      Directives.async_task(
        {Aikido.Team.MemberProcesses, :start_member,
         [
           spec.resource,
           Topology.member_id(state.topology, context.agent_id, name),
           initial,
           parent,
           context
         ]},
        success_type: "aikido.ash.team.started",
        error_type: "aikido.ash.team.failed",
        payload: %{
          member: name,
          operation_id: state.operation.id,
          reference:
            Aikido.Agent.Reference.new!(
              id: Topology.member_id(state.topology, context.agent_id, name),
              resource: spec.resource,
              aikido: config.instance,
              partition: context.partition
            )
        }
      )

    {:ok, put_in(state.operation.awaiting, {:start, name}), [effect]}
  end

  defp request_member_inheritance(state, name, pid, context, config) do
    changes =
      state.topology.nodes[name]
      |> inherited_member_state(context, config)
      |> Map.take(Map.get(config, :reconcile_inherit, []))

    signal = %Signal{
      type: "aikido.agent.inherit",
      data: %{operation_id: state.operation.id, member: name, changes: changes},
      source: "/aikido"
    }

    effect =
      Aikido.Team.Directives.Deliver.new!(
        signal: signal,
        target: pid,
        kind: :inheritance,
        signal_type: signal.type
      )

    {:ok, put_in(state.operation.awaiting, {:inherit, name}), [effect]}
  end

  @doc "Adopt only a correlated active member acknowledgement before advancing the tracked plan."
  def inherited(data, state, context, config) do
    if awaited?(state, data.operation_id, {:inherit, data.member}) do
      if is_nil(data.error) do
        advance_member_lifecycle(state, context, config)
      else
        fail_operation_and_pending_tasks(
          %{
            operation_id: data.operation_id,
            reason: {:inheritance_failed, data.member, data.error}
          },
          state,
          context
        )
      end
    else
      {:ok, state, []}
    end
  end

  defp member_parent(state, name, owner, context, config) do
    %{
      pid: if(owner, do: state.members[owner], else: context.agent_pid),
      id:
        if(owner,
          do: Topology.member_id(state.topology, context.agent_id, owner),
          else: context.agent_id
        ),
      tag: name,
      partition: context.partition,
      meta: %{
        team_id: context.agent_id,
        team_resource: config.resource,
        team_pid: context.agent_pid,
        member: name
      }
    }
  end

  defp inherited_member_state(spec, context, config) do
    context.agent.state
    |> Map.get(config.state_path, %{})
    |> Map.take(config.inherit)
    |> Map.merge(spec.initial_state)
  end

  def fail_operation_and_pending_tasks(%{operation_id: id, reason: reason}, state, context) do
    if state.operation.id == id && state.operation.status == :running do
      pending = Map.keys(Map.get(state, :pending_tasks, %{}))

      state
      |> mark_operation_failed(reason)
      |> record_pending_task_failures(reason)
      |> result_with_task_notifications(pending, context)
    else
      {:ok, state, []}
    end
  end

  defp mark_operation_failed(state, reason) do
    %{state | operation: %{state.operation | status: :failed, error: reason}}
  end

  defp record_pending_task_failures(state, reason) do
    tasks =
      Map.new(Map.get(state, :pending_tasks, %{}), fn {id, data} ->
        {id,
         %{
           id: id,
           member: data.member,
           status: :failed,
           result: reason,
           attempt: nil,
           notify: Aikido.Team.TaskDelivery.notification_recipient(data),
           requester: data[:requester],
           mode: Map.get(data, :mode, :background),
           metadata: data[:metadata] || %{}
         }
         |> Aikido.Team.TaskDelivery.bind_requester_run(data)}
      end)

    Map.merge(state, %{pending_tasks: %{}, tasks: Map.merge(state.tasks, tasks)})
  end

  defp result_with_task_notifications(state, ids, context) do
    directives =
      Enum.flat_map(
        ids,
        &TaskDelivery.task_result_delivery_directives(state.tasks[&1], state, context)
      )

    {state, inherited} = settle_inheritance_reply(state, inheritance_error(state.operation.error))
    {state, queued} = release_queued_operations(state, context)

    {:ok, state,
     Aikido.Team.MemberStop.release_monitor(state) ++ directives ++ inherited ++ queued}
  end

  defp settle_inheritance_reply(state, error) do
    case Map.get(state.operation, :inheritance_reply) do
      nil ->
        {state, []}

      reply ->
        effect =
          Aikido.Team.Delivery.inheritance_result(
            reply.pid,
            reply.operation_id,
            reply.member,
            error
          )

        {put_in(state.operation, Map.delete(state.operation, :inheritance_reply)), [effect]}
    end
  end

  defp inheritance_error(:timeout),
    do:
      "The nested team's inherited configuration operation timed out before all members acknowledged it."

  defp inheritance_error({:inheritance_failed, member, message}),
    do: "Inherited configuration was rejected by member #{inspect(member)}: #{message}"

  defp inheritance_error(_reason),
    do:
      "The nested team could not reconcile inherited configuration. Inspect its failed operation before retrying."

  def awaited?(state, id, step),
    do:
      state.operation.id == id && state.operation.status == :running &&
        state.operation.awaiting == step
end
