defmodule Aikido.Actions.Lifecycle do
  @moduledoc "Base actions for agent lifecycle and coordination patterns.\n\nThese actions provide common patterns for:\n- Parent-child communication\n- Process spawning\n- Graceful termination\n\n## Usage\n\n    use Aikido.Agent\n\n    agent do\n      name \"coordinator_agent\"\n    end\n\n    signal_routes do\n      route \"work.done\", Aikido.Actions.Lifecycle.NotifyParent\n      route \"spawn.worker\", Aikido.Actions.Lifecycle.SpawnChild\n      route \"shutdown\", Aikido.Actions.Lifecycle.StopSelf\n    end\n"
  alias Aikido.Directives
  alias Jido.Signal

  defmodule NotifyParent do
    @moduledoc "Emit a signal back to the spawning parent agent.\n\nReads the current parent reference from `ctx.parent` (a `%ParentRef{}`\nseeded by AgentServer). When the agent is orphaned, `ctx.parent` is\n`nil` and the action emits no directive.\n\n## Schema\n\n- `signal_type` - Signal type to emit (required)\n- `payload` - Signal payload data (default: %{})\n- `source` - Signal source path (default: \"/child\")\n\n## Example\n\n    # Route child completion to this action\n    {\"work.complete\", Aikido.Actions.Lifecycle.NotifyParent}\n\n    # Or invoke directly with params\n    {Aikido.Actions.Lifecycle.NotifyParent, %{signal_type: \"child.done\", payload: %{result: 42}}}\n"
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "notify_parent", description: "Emit a signal back to the parent agent"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        argument(:signal_type, :string,
          description: "Signal type to emit to parent",
          allow_nil?: false
        )

        argument(:payload, :map, description: "Signal payload data", default: %{})
        argument(:source, :string, description: "Signal source path", default: "/child")
        description("Emit a signal back to the parent agent")

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(
           %Jido.Signal{data: %{signal_type: type, payload: payload, source: source}},
           _slice,
           _opts,
           ctx
         ) do
      signal = Signal.new!(type, payload, source: source)

      directive =
        case Map.get(ctx, :parent) do
          %Aikido.AgentServer.ParentRef{pid: pid} when is_pid(pid) ->
            Directives.emit_to_pid(signal, pid)

          _ ->
            nil
        end

      {:ok, %{notified: directive != nil}, List.wrap(directive)}
    end
  end

  defmodule NotifyPid do
    @moduledoc "Emit a signal to an arbitrary process by PID.\n\n## Schema\n\n- `target_pid` - PID to send signal to (required)\n- `signal_type` - Signal type to emit (required)\n- `payload` - Signal payload data (default: %{})\n- `source` - Signal source path (default: \"/agent\")\n- `delivery_mode` - :async (default) or :sync\n\n## Example\n\n    {Aikido.Actions.Lifecycle.NotifyPid, %{\n      target_pid: some_pid,\n      signal_type: \"result.ready\",\n      payload: %{data: result}\n    }}\n"
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "notify_pid", description: "Emit a signal to a specific process"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:target_pid, :term, description: "Target process PID", allow_nil?: false)
        argument(:signal_type, :string, description: "Signal type to emit", allow_nil?: false)
        argument(:payload, :map, description: "Signal payload data", default: %{})
        argument(:source, :string, description: "Signal source path", default: "/agent")

        argument(:delivery_mode, Aikido.Types.Native,
          description: "Delivery mode",
          default: :async,
          constraints: [kind: {:in, [:async, :sync]}]
        )

        description("Emit a signal to a specific process")

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(
           %Jido.Signal{
             data: %{
               target_pid: pid,
               signal_type: type,
               payload: payload,
               source: source,
               delivery_mode: mode
             }
           },
           _slice,
           _opts,
           _ctx
         ) do
      signal = Signal.new!(type, payload, source: source)
      directive = Directives.emit_to_pid(signal, pid, delivery_mode: mode)
      {:ok, %{sent_to: pid}, [directive]}
    end
  end

  defmodule SpawnChild do
    @moduledoc "Spawn a child agent with hierarchy tracking.\n\nThe spawned agent will have its `ctx.parent` populated so its actions\ncan address the parent directly via\n`%Directives.Emit{dispatch: {:pid, target: ctx.parent.pid}}`.\n\n## Schema\n\n- `agent_module` - Agent module to spawn (required)\n- `tag` - Tag for tracking this child (required)\n- `initial_state` - Initial state for the child agent (default: %{})\n- `meta` - Metadata to pass to child (default: %{})\n- `restart` - Restart policy for the child (default: `:transient`)\n\n## Example\n\n    {\"coordinator.spawn\", Aikido.Actions.Lifecycle.SpawnChild}\n\n    # With params\n    {Aikido.Actions.Lifecycle.SpawnChild, %{\n      agent_module: MyWorker,\n      tag: :worker_1,\n      initial_state: %{batch_size: 100},\n      restart: :permanent\n    }}\n"
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "spawn_child", description: "Spawn a child agent with hierarchy tracking"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:agent_module, :atom, description: "Agent module to spawn", allow_nil?: false)
        argument(:tag, :atom, description: "Tag for tracking this child", allow_nil?: false)
        argument(:initial_state, :map, description: "Initial state for child", default: %{})
        argument(:meta, :map, description: "Metadata to pass to child", default: %{})

        argument(:restart, Aikido.Types.Native,
          description: "Restart policy for the child",
          default: :transient,
          constraints: [kind: {:in, Directives.valid_restart_policies()}]
        )

        description("Spawn a child agent with hierarchy tracking")

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(
           %Jido.Signal{
             data: %{
               agent_module: mod,
               tag: tag,
               initial_state: state,
               meta: meta,
               restart: restart
             }
           },
           _slice,
           _opts,
           _ctx
         ) do
      opts =
        if state == %{} do
          %{}
        else
          %{initial_state: state}
        end

      directive = Directives.spawn_agent(mod, tag, opts: opts, meta: meta, restart: restart)
      {:ok, %{spawning: tag}, [directive]}
    end
  end

  defmodule StopSelf do
    @moduledoc "Request graceful termination of the current agent process.\n\n## Schema\n\n- `reason` - Reason for stopping (default: :normal)\n\n## Example\n\n    {\"shutdown\", Aikido.Actions.Lifecycle.StopSelf}\n\n    # With custom reason\n    {Aikido.Actions.Lifecycle.StopSelf, %{reason: :work_complete}}\n"
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "stop_self", description: "Request graceful termination of this agent"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:reason, :term, description: "Reason for stopping", default: :normal)
        description("Request graceful termination of this agent")

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(%Jido.Signal{data: %{reason: reason}}, _slice, _opts, _ctx) do
      directive = Directives.stop(reason)
      {:ok, %{stopping: true, reason: reason}, [directive]}
    end
  end

  defmodule StopChild do
    @moduledoc "Request graceful termination of a tracked child agent.\n\n## Schema\n\n- `tag` - Tag of the child to stop (required)\n- `reason` - Reason for stopping (default: :normal)\n\n## Example\n\n    {\"coordinator.stop_worker\", Aikido.Actions.Lifecycle.StopChild}\n\n    {Aikido.Actions.Lifecycle.StopChild, %{tag: :worker_1, reason: :shutdown}}\n"
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "stop_child", description: "Request graceful termination of a child agent"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:tag, :atom, description: "Tag of child to stop", allow_nil?: false)
        argument(:reason, :term, description: "Reason for stopping", default: :normal)
        description("Request graceful termination of a child agent")

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(%Jido.Signal{data: %{tag: tag, reason: reason}}, _slice, _opts, _ctx) do
      directive = Directives.stop_child(tag, reason)
      {:ok, %{stopping_child: tag, reason: reason}, [directive]}
    end
  end
end
