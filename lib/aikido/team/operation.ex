defmodule Aikido.Team.Operation do
  @moduledoc "Pure topology plan validation, lifecycle sequencing and operation correlation."
  alias Aikido.Team.{Tasks, Topology}
  alias Aikido.Directives
  alias Aikido.Signal

  def begin_topology_change(_signal, %{operation: %{status: :running}}, _context, _config, _plan),
    do: {:error, :operation_in_progress}

  def begin_topology_change(signal, state, context, config, plan) do
    with {:ok, topology, stop, requested, paused} <- plan.(),
         :ok <- validate_worker_limits(topology, config),
         {:ok, steps} <- order_member_steps(state.topology, topology, stop, requested) do
      state
      |> adopt_topology(topology, paused)
      |> begin_operation(signal.id, steps)
      |> advance_member_lifecycle(context, config)
      |> append_operation_deadline(signal.id, config.timeout)
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

    {:ok, Map.put(state, :recovered_tasks, []), directives}
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
        request_member_stop(state, name, pid, config)

      {:start, nil} ->
        request_member_start(state, name, context, config)
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
      Tasks.task_result_delivery_directives(state.tasks[id], state, context)
    end)
  end

  defp request_member_stop(state, name, pid, config) do
    effect =
      Directives.async_task({Aikido.Team.Runtime, :stop_member, [config.instance, pid]},
        success_type: "aikido.ash.team.stopped",
        error_type: "aikido.ash.team.failed",
        payload: %{member: name, operation_id: state.operation.id, pid: pid}
      )

    {:ok, put_in(state.operation.awaiting, {:stop, name}), [effect]}
  end

  defp request_member_start(state, name, context, config) do
    spec = state.topology.nodes[name]
    parent = member_parent(state, name, spec.owner, context, config)
    initial = inherited_member_state(spec, context, config)

    effect =
      Directives.async_task(
        {Aikido.Team.Runtime, :start_member,
         [spec.resource, member_id(context.agent_id, name), initial, parent, context]},
        success_type: "aikido.ash.team.started",
        error_type: "aikido.ash.team.failed",
        payload: %{member: name, operation_id: state.operation.id}
      )

    {:ok, put_in(state.operation.awaiting, {:start, name}), [effect]}
  end

  defp member_parent(state, name, owner, context, config) do
    %{
      pid: if(owner, do: state.members[owner], else: context.agent_pid),
      id: if(owner, do: member_id(context.agent_id, owner), else: context.agent_id),
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
           notify: data[:notify],
           metadata: data[:metadata] || %{}
         }}
      end)

    Map.merge(state, %{pending_tasks: %{}, tasks: Map.merge(state.tasks, tasks)})
  end

  defp result_with_task_notifications(state, ids, context) do
    directives =
      Enum.flat_map(ids, &Tasks.task_result_delivery_directives(state.tasks[&1], state, context))

    {:ok, state, directives}
  end

  def awaited?(state, id, step),
    do:
      state.operation.id == id && state.operation.status == :running &&
        state.operation.awaiting == step

  defp member_id(id, name), do: id <> "/" <> to_string(name)
end
