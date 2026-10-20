defmodule Aikido.Ash.Team.Operation do
  @moduledoc "Pure topology plan validation, lifecycle sequencing and operation correlation."
  alias Aikido.Ash.Team.{Tasks, Topology}
  alias Aikido.Directives
  alias Aikido.Signal

  def start(_signal, %{operation: %{status: :running}}, _context, _config, _plan),
    do: {:error, :operation_in_progress}

  def start(signal, state, context, config, plan) do
    with {:ok, topology, stop, requested, paused} <- plan.(),
         :ok <- validate_limits(topology, config),
         {:ok, stops} <- Topology.order(state.topology.nodes, stop),
         {:ok, starts} <- Topology.order(topology.nodes, Topology.targets(topology, requested)) do
      steps = Enum.map(Enum.reverse(stops), &{:stop, &1}) ++ Enum.map(starts, &{:start, &1})

      version =
        if topology.nodes == state.topology.nodes,
          do: state.topology.version,
          else: state.topology.version + 1

      operation = %{
        id: signal.id,
        status: :running,
        remaining: steps,
        awaiting: nil,
        started: [],
        stopped: [],
        error: nil
      }

      state = %{
        state
        | topology: %{topology | version: version},
          paused: paused,
          operation: operation
      }

      {:ok, state, directives} = advance(state, context, config)

      timer =
        Directives.schedule(
          config.timeout,
          %Signal{
            id: nil,
            type: "aikido.ash.team.timeout",
            data: %{operation_id: signal.id},
            source: "/aikido"
          }
        )

      {:ok, state, directives ++ [timer]}
    end
  end

  defp validate_limits(topology, config) do
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

  def advance(%{operation: %{remaining: []}} = state, context, _config) do
    state = put_in(state.operation.status, :completed)

    completed =
      %Signal{
        id: nil,
        type: "aikido.ash.team.operation.completed",
        data: %{operation_id: state.operation.id},
        source: "/aikido"
      }

    pending = Map.get(state, :pending_tasks, %{})

    dispatch =
      Enum.map(pending, fn {id, data} ->
        Directives.emit(%Signal{
          id: nil,
          type: "aikido.ash.team.assign_task",
          data: Map.put(data, :task_id, id),
          source: "/aikido"
        })
      end)

    recovered =
      Enum.flat_map(Map.get(state, :recovered_tasks, []), fn id ->
        Tasks.notify(state.tasks[id], state, context)
      end)

    state = Map.put(state, :recovered_tasks, [])
    {:ok, state, [Directives.emit_to_pid(completed, context.agent_pid)] ++ dispatch ++ recovered}
  end

  def advance(%{operation: %{remaining: [{kind, name} | rest]}} = state, context, config) do
    state = put_in(state.operation.remaining, rest)

    case {kind, Map.get(state.members, name)} do
      {:stop, nil} ->
        advance(state, context, config)

      {:start, pid} when is_pid(pid) ->
        advance(state, context, config)

      {:stop, pid} ->
        payload = %{member: name, operation_id: state.operation.id, pid: pid}

        effect =
          Directives.async_task({Aikido.Ash.Team.Runtime, :stop_member, [config.instance, pid]},
            success_type: "aikido.ash.team.stopped",
            error_type: "aikido.ash.team.failed",
            payload: payload
          )

        {:ok, put_in(state.operation.awaiting, {:stop, name}), [effect]}

      {:start, nil} ->
        spec = state.topology.nodes[name]
        parent_pid = if spec.owner, do: state.members[spec.owner], else: context.agent_pid

        parent_id =
          if spec.owner, do: member_id(context.agent_id, spec.owner), else: context.agent_id

        parent = %{
          pid: parent_pid,
          id: parent_id,
          tag: name,
          partition: context.partition,
          meta: %{
            team_id: context.agent_id,
            team_resource: config.resource,
            team_pid: context.agent_pid,
            member: name
          }
        }

        payload = %{member: name, operation_id: state.operation.id}

        effect =
          Directives.async_task(
            {Aikido.Ash.Team.Runtime, :start_member,
             [
               spec.resource,
               member_id(context.agent_id, name),
               Map.merge(
                 Map.take(Map.get(context.agent.state, config.state_path, %{}), config.inherit),
                 spec.initial_state
               ),
               parent,
               context
             ]},
            success_type: "aikido.ash.team.started",
            error_type: "aikido.ash.team.failed",
            payload: payload
          )

        {:ok, put_in(state.operation.awaiting, {:start, name}), [effect]}
    end
  end

  def failed(%{operation_id: id, reason: reason}, state, context) do
    if state.operation.id == id && state.operation.status == :running do
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

      state =
        Map.merge(state, %{
          operation: %{state.operation | status: :failed, error: reason},
          pending_tasks: %{},
          tasks: Map.merge(state.tasks, tasks)
        })

      {:ok, state, Enum.flat_map(Map.values(tasks), &Tasks.notify(&1, state, context))}
    else
      {:ok, state, []}
    end
  end

  def awaited?(state, id, step),
    do:
      state.operation.id == id && state.operation.status == :running &&
        state.operation.awaiting == step

  defp member_id(id, name), do: id <> "/" <> to_string(name)
end
