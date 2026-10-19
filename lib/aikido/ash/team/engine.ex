defmodule Aikido.Ash.Team.Engine do
  @moduledoc false
  alias Aikido.Ash.Team.Topology
  alias Aikido.Directives
  alias Jido.Signal

  def handle(signal, state, context, config) do
    case signal.type do
      "aikido.ash.team.started" -> started(signal.data, state, context, config)
      "aikido.ash.team.stopped" -> stopped(signal.data, state, context, config)
      "aikido.ash.team.failed" -> failed(signal.data, state, context)
      "aikido.ash.team.exited" -> exited(signal.data, state, context, config)
      "aikido.ash.team.timeout" -> timeout(signal.data, state, context)
      "aikido.agent.child.started" -> {:ok, state, []}
      "aikido.agent.child.exit" -> {:ok, state, []}
      "aikido.ash.team.send" -> send_message(signal.data, state)
      "aikido.ash.team.broadcast" -> broadcast(signal.data, state)
      "aikido.ash.team.assign_task" -> request_task(signal, state, context, config)
      "aikido.ash.team.task.completed" -> task_result(signal.data, state, :completed, context)
      "aikido.ash.team.task.failed" -> task_result(signal.data, state, :failed, context)
      "aikido.ash.team.task.timeout" -> task_timeout(signal.data, state, context)
      "aikido.ash.team.operation.completed" -> {:ok, state, []}
      "aikido.ash.team.cleanup" -> {:ok, state, []}
      _ -> command(signal, state, context, config)
    end
  end

  defp command(_signal, %{operation: %{status: :running}}, _context, _config),
    do: {:error, :operation_in_progress}

  defp command(signal, state, context, config) do
    with {:ok, topology, stop, requested, paused} <- plan(signal, state, config),
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
          struct!(Signal,
            id: nil,
            type: "aikido.ash.team.timeout",
            data: %{operation_id: signal.id},
            source: "/aikido"
          )
        )

      {:ok, state, directives ++ [timer]}
    end
  end

  defp plan(%{type: type, data: data}, state, config) do
    case String.replace_prefix(type, "aikido.ash.team.", "") do
      "start" ->
        with {:ok, next} <-
               Topology.build(
                 data[:topology] || state.topology.nodes,
                 config.instance,
                 config.max_members
               ) do
          changed =
            for {name, spec} <- state.topology.nodes, Map.get(next.nodes, name) != spec, do: name

          affected = Topology.affected(state.topology, changed)

          retained =
            Enum.filter(
              affected,
              &(Map.has_key?(state.members, &1) && Map.has_key?(next.nodes, &1))
            )

          {:ok, next, affected, Enum.uniq(Topology.eager(next) ++ retained), %{}}
        end

      "reconcile" ->
        {:ok, state.topology, [],
         Enum.reject(Topology.eager(state.topology), &Map.has_key?(state.paused, &1)),
         state.paused}

      "add_member" ->
        with {:ok, spec} <- member_spec(data, state, config),
             {:ok, next} <-
               Topology.put(
                 state.topology,
                 data.member,
                 spec,
                 config.instance,
                 config.max_members
               ) do
          {:ok, next, [], if(spec.activation == :eager, do: [data.member], else: []),
           state.paused}
        end

      "remove_member" ->
        with {:ok, next, removed} <-
               Topology.remove(state.topology, data.member, Map.get(data, :cascade?, false)) do
          {:ok, next, removed, [], Map.drop(state.paused, removed)}
        end

      "ensure_member" ->
        if Map.has_key?(state.topology.nodes, data.member),
          do: {:ok, state.topology, [], [data.member], Map.delete(state.paused, data.member)},
          else: {:error, {:unknown_member, data.member}}

      "stop_member" ->
        with {:ok, _next, stopped} <- Topology.remove(state.topology, data.member, true) do
          {:ok, state.topology, stopped, [],
           Map.merge(state.paused, Map.new(stopped, &{&1, true}))}
        end

      _ ->
        {:error, :unknown_team_command}
    end
  end

  defp member_spec(data, state, config) do
    template = Map.get(data, :template)

    definition =
      if template,
        do: Map.get(config.workers, template),
        else: %{resource: Map.get(data, :resource)}

    count = Enum.count(state.topology.nodes, fn {_, spec} -> spec.template == template end)

    cond do
      is_nil(definition) ->
        {:error, {:unknown_worker_template, template}}

      template && count >= definition.max_members ->
        {:error, {:worker_limit, template}}

      true ->
        {:ok,
         %{
           resource: definition.resource,
           template: template,
           initial_state:
             DeepMerge.deep_merge(
               Map.get(definition, :initial_state, %{}),
               Map.get(data, :initial_state, %{})
             ),
           owner: Map.get(data, :owner),
           depends_on: Map.get(data, :depends_on, []),
           activation: Map.get(data, :activation, :eager)
         }}
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
            if Enum.all?(topology.nodes, fn {_, spec} ->
                 spec.template != template || spec.resource == resource
               end),
               do: {:cont, :ok},
               else: {:halt, {:error, {:template_resource_mismatch, template}}}

          _ ->
            {:halt, {:error, {:worker_limit, template}}}
        end
    end)
  end

  defp advance(%{operation: %{remaining: []}} = state, context, _config) do
    state = put_in(state.operation.status, :completed)

    completed =
      struct!(Signal,
        id: nil,
        type: "aikido.ash.team.operation.completed",
        data: %{operation_id: state.operation.id},
        source: "/aikido"
      )

    pending = Map.get(state, :pending_tasks, %{})

    dispatch =
      Enum.map(pending, fn {id, data} ->
        Directives.emit(
          struct!(Signal,
            id: nil,
            type: "aikido.ash.team.assign_task",
            data: Map.put(data, :task_id, id),
            source: "/aikido"
          )
        )
      end)

    recovered =
      Enum.flat_map(Map.get(state, :recovered_tasks, []), fn id ->
        notify(state.tasks[id], state, context)
      end)

    state = Map.put(state, :recovered_tasks, [])
    {:ok, state, [Directives.emit_to_pid(completed, context.agent_pid)] ++ dispatch ++ recovered}
  end

  defp advance(%{operation: %{remaining: [{kind, name} | rest]}} = state, context, config) do
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
               parent
             ]},
            success_type: "aikido.ash.team.started",
            error_type: "aikido.ash.team.failed",
            payload: payload
          )

        {:ok, put_in(state.operation.awaiting, {:start, name}), [effect]}
    end
  end

  defp started(%{member: name, operation_id: id, result: pid}, state, context, config) do
    if awaited?(state, id, {:start, name}) do
      state = %{
        state
        | members: Map.put(state.members, name, pid),
          incarnations: Map.put(state.incarnations, name, id)
      }

      state = update_in(state.operation.started, &(&1 ++ [name]))

      watch =
        Directives.async_task({Aikido.Ash.Team.Runtime, :watch_member, [pid, context.agent_pid]},
          success_type: "aikido.ash.team.exited",
          error_type: "aikido.ash.team.exited",
          payload: %{member: name, pid: pid, incarnation: id}
        )

      {:ok, next, directives} = advance(state, context, config)
      {:ok, next, [watch | directives]}
    else
      # A timed-out activation must not leave an untracked worker running.
      effects =
        if pid in Map.values(state.members),
          do: [],
          else: [
            Directives.async_task({Aikido.Ash.Team.Runtime, :stop_member, [config.instance, pid]},
              success_type: "aikido.ash.team.cleanup",
              error_type: "aikido.ash.team.cleanup"
            )
          ]

      {:ok, state, effects}
    end
  end

  defp stopped(%{member: name, operation_id: id}, state, context, config) do
    if awaited?(state, id, {:stop, name}) do
      state = %{
        state
        | members: Map.delete(state.members, name),
          incarnations: Map.delete(state.incarnations, name)
      }

      state = update_in(state.operation.stopped, &(&1 ++ [name]))
      advance(state, context, config)
    else
      {:ok, state, []}
    end
  end

  defp failed(%{operation_id: id, reason: reason}, state, context) do
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

      {:ok, state, Enum.flat_map(Map.values(tasks), &notify(&1, state, context))}
    else
      {:ok, state, []}
    end
  end

  defp timeout(%{operation_id: id}, state, context),
    do: failed(%{operation_id: id, reason: :timeout}, state, context)

  defp exited(%{member: name, pid: pid} = data, state, context, _config) do
    if Map.get(state.members, name) == pid do
      tasks =
        Map.new(state.tasks, fn {id, task} ->
          {id,
           if(task.member == name && task.status == :dispatched,
             do: %{task | status: :failed, result: :member_exited},
             else: task
           )}
        end)

      previous = state

      state = %{
        state
        | members: Map.delete(state.members, name),
          incarnations: Map.delete(state.incarnations, name),
          failures: Map.put(state.failures, name, Map.get(data, :result, Map.get(data, :reason))),
          tasks: tasks
      }

      notifications =
        for {id, task} <- tasks,
            task.status == :failed && previous.tasks[id].status == :dispatched,
            effect <- notify(task, state, context),
            do: effect

      reconcile =
        if Map.has_key?(state.topology.nodes, name) && !Map.has_key?(state.paused, name) &&
             state.operation.status != :running,
           do: [
             Directives.emit(
               struct!(Signal,
                 id: nil,
                 type: "aikido.ash.team.ensure_member",
                 data: %{member: name},
                 source: "/aikido"
               )
             )
           ],
           else: []

      {:ok, state, notifications ++ reconcile}
    else
      {:ok, state, []}
    end
  end

  defp send_message(data, state) do
    with {:ok, pid} <- fetch_member(state, data.member) do
      signal =
        struct!(Signal,
          id: nil,
          type: data.type,
          data: Map.get(data, :payload, %{}),
          source: "/ash/team"
        )

      {:ok, state, [Directives.emit_to_pid(signal, pid)]}
    end
  end

  defp broadcast(data, state) do
    targets = data[:members] || Map.keys(state.members)

    with {:ok, pids} <-
           Enum.reduce_while(targets, {:ok, []}, fn name, {:ok, pids} ->
             case fetch_member(state, name) do
               {:ok, pid} -> {:cont, {:ok, [pid | pids]}}
               error -> {:halt, error}
             end
           end) do
      signal =
        struct!(Signal,
          id: nil,
          type: data.type,
          data: Map.get(data, :payload, %{}),
          source: "/ash/team"
        )

      {:ok, state, Enum.map(pids, &Directives.emit_to_pid(signal, &1))}
    end
  end

  defp request_task(signal, state, context, config) do
    id = signal.data[:task_id] || signal.id

    cond do
      Map.has_key?(state.tasks, id) ->
        {:error, {:task_exists, id}}

      Map.has_key?(state.members, signal.data.member) ->
        state = Map.update(state, :pending_tasks, %{}, &Map.delete(&1, id))
        assign_task(signal, state, context)

      Map.has_key?(Map.get(state, :pending_tasks, %{}), id) ->
        {:error, :operation_in_progress}

      Map.has_key?(state.topology.nodes, signal.data.member) ->
        state =
          Map.update(state, :pending_tasks, %{id => signal.data}, &Map.put(&1, id, signal.data))

        command(
          %{signal | type: "aikido.ash.team.ensure_member", data: %{member: signal.data.member}},
          state,
          context,
          config
        )

      true ->
        {:error, {:unknown_member, signal.data.member}}
    end
  end

  defp assign_task(signal, state, context) do
    data = signal.data
    id = Map.get(data, :task_id) || signal.id

    with true <- !Map.has_key?(state.tasks, id) || {:error, {:task_exists, id}},
         {:ok, pid} <- fetch_member(state, data.member),
         outgoing =
           struct!(Signal,
             id: nil,
             type: Map.get(data, :type, "harness.task"),
             data:
               Map.merge(Map.get(data, :payload, %{}), %{
                 metadata: data[:metadata] || %{},
                 task_id: id,
                 member: data.member,
                 reply_to: context.agent_pid,
                 attempt: state.incarnations[data.member]
               }),
             source: "/ash/team"
           ) do
      task = %{
        id: id,
        member: data.member,
        status: :dispatched,
        result: nil,
        notify: data[:notify],
        metadata: data[:metadata] || %{},
        attempt: state.incarnations[data.member]
      }

      effects = [Directives.emit_to_pid(outgoing, pid)]
      timeout = Map.get(data, :timeout_ms, 30_000)

      effects =
        if is_integer(timeout) && timeout > 0,
          do:
            effects ++
              [
                Directives.schedule(
                  timeout,
                  struct!(Signal,
                    id: nil,
                    type: "aikido.ash.team.task.timeout",
                    data: %{
                      task_id: id,
                      attempt: task.attempt
                    },
                    source: "/aikido"
                  )
                )
              ],
          else: effects

      {:ok, put_in(state.tasks[id], task), effects}
    end
  end

  defp task_result(data, state, status, context) do
    case Map.get(state.tasks, data.task_id) do
      %{status: :dispatched, attempt: attempt, member: member} = task
      when attempt == data.attempt and member == data.member ->
        task = %{task | status: status, result: Map.get(data, :result, Map.get(data, :reason))}
        state = put_in(state.tasks[data.task_id], task)
        {:ok, state, notify(task, state, context)}

      _ ->
        {:ok, state, []}
    end
  end

  defp task_timeout(data, state, context) do
    case Map.get(state.tasks, data.task_id) do
      %{status: :dispatched, attempt: attempt} = task when attempt == data.attempt ->
        task = %{task | status: :failed, result: :timeout}
        state = put_in(state.tasks[data.task_id], task)

        cancel =
          case state.members[task.member] do
            nil ->
              []

            pid ->
              [
                Directives.emit_to_pid(
                  struct!(Signal,
                    id: nil,
                    type: "harness.cancel_task",
                    data: %{task_id: task.id},
                    source: "/aikido"
                  ),
                  pid
                )
              ]
          end

        {:ok, state, cancel ++ notify(task, state, context)}

      _ ->
        {:ok, state, []}
    end
  end

  defp notify(task, state, context) do
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
        struct!(Signal,
          id: nil,
          type: "ai.react.deliver",
          data: %{
            text: text,
            request_id: "task-result/" <> task.id,
            metadata: %{task: Map.take(task, [:id, :member, :status, :result, :metadata])}
          },
          source: "/aikido"
        )

      [Directives.emit_to_pid(signal, pid)]
    else
      []
    end
  end

  defp fetch_member(state, name) do
    case Map.fetch(state.members, name) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, {:member_not_running, name}}
    end
  end

  defp awaited?(state, id, step),
    do:
      state.operation.id == id && state.operation.status == :running &&
        state.operation.awaiting == step

  defp member_id(id, name), do: id <> "/" <> to_string(name)
end
