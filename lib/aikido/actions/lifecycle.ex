defmodule Aikido.Actions.Lifecycle do
  @moduledoc """
  Base actions for agent lifecycle and coordination patterns.

  These actions provide common patterns for:
  - Parent-child communication
  - Process spawning
  - Graceful termination

  ## Usage

      use Aikido.Agent

      agent do
        name "coordinator_agent"
      end

      signal_routes do
        route "work.done", Aikido.Actions.Lifecycle.NotifyParent
        route "spawn.worker", Aikido.Actions.Lifecycle.SpawnChild
        route "shutdown", Aikido.Actions.Lifecycle.StopSelf
      end
  """

  alias Aikido.Directives
  alias Jido.Signal

  defmodule NotifyParent do
    @moduledoc """
    Emit a signal back to the spawning parent agent.

    Reads the current parent reference from `ctx.parent` (a `%ParentRef{}`
    seeded by AgentServer). When the agent is orphaned, `ctx.parent` is
    `nil` and the action emits no directive.

    ## Schema

    - `signal_type` - Signal type to emit (required)
    - `payload` - Signal payload data (default: %{})
    - `source` - Signal source path (default: "/child")

    ## Example

        # Route child completion to this action
        {"work.complete", Aikido.Actions.Lifecycle.NotifyParent}

        # Or invoke directly with params
        {Aikido.Actions.Lifecycle.NotifyParent, %{signal_type: "child.done", payload: %{result: 42}}}
    """
    use Aikido.Action

    action do
      name "notify_parent"
      description "Emit a signal back to the parent agent"

      schema do
        attribute :signal_type, :string,
          description: "Signal type to emit to parent",
          allow_nil?: false

        attribute :payload, :map, description: "Signal payload data", default: %{}
        attribute :source, :string, description: "Signal source path", default: "/child"
      end
    end

    def run(
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
    @moduledoc """
    Emit a signal to an arbitrary process by PID.

    ## Schema

    - `target_pid` - PID to send signal to (required)
    - `signal_type` - Signal type to emit (required)
    - `payload` - Signal payload data (default: %{})
    - `source` - Signal source path (default: "/agent")
    - `delivery_mode` - :async (default) or :sync

    ## Example

        {Aikido.Actions.Lifecycle.NotifyPid, %{
          target_pid: some_pid,
          signal_type: "result.ready",
          payload: %{data: result}
        }}
    """
    use Aikido.Action

    action do
      name "notify_pid"
      description "Emit a signal to a specific process"

      schema do
        attribute :target_pid, :term, description: "Target process PID", allow_nil?: false
        attribute :signal_type, :string, description: "Signal type to emit", allow_nil?: false
        attribute :payload, :map, description: "Signal payload data", default: %{}
        attribute :source, :string, description: "Signal source path", default: "/agent"

        attribute :delivery_mode, Aikido.Types.Native,
          description: "Delivery mode",
          default: :async,
          constraints: [kind: {:in, [:async, :sync]}]
      end
    end

    def run(
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
    @moduledoc """
    Spawn a child agent with hierarchy tracking.

    The spawned agent will have its `ctx.parent` populated so its actions
    can address the parent directly via
    `%Directives.Emit{dispatch: {:pid, target: ctx.parent.pid}}`.

    ## Schema

    - `agent_module` - Agent module to spawn (required)
    - `tag` - Tag for tracking this child (required)
    - `initial_state` - Initial state for the child agent (default: %{})
    - `meta` - Metadata to pass to child (default: %{})
    - `restart` - Restart policy for the child (default: `:transient`)

    ## Example

        {"coordinator.spawn", Aikido.Actions.Lifecycle.SpawnChild}

        # With params
        {Aikido.Actions.Lifecycle.SpawnChild, %{
          agent_module: MyWorker,
          tag: :worker_1,
          initial_state: %{batch_size: 100},
          restart: :permanent
        }}
    """
    use Aikido.Action

    action do
      name "spawn_child"
      description "Spawn a child agent with hierarchy tracking"

      schema do
        attribute :agent_module, :atom, description: "Agent module to spawn", allow_nil?: false
        attribute :tag, :atom, description: "Tag for tracking this child", allow_nil?: false
        attribute :initial_state, :map, description: "Initial state for child", default: %{}
        attribute :meta, :map, description: "Metadata to pass to child", default: %{}

        attribute :restart, Aikido.Types.Native,
          description: "Restart policy for the child",
          default: :transient,
          constraints: [kind: {:in, Directives.valid_restart_policies()}]
      end
    end

    def run(
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
    @moduledoc """
    Request graceful termination of the current agent process.

    ## Schema

    - `reason` - Reason for stopping (default: :normal)

    ## Example

        {"shutdown", Aikido.Actions.Lifecycle.StopSelf}

        # With custom reason
        {Aikido.Actions.Lifecycle.StopSelf, %{reason: :work_complete}}
    """
    use Aikido.Action

    action do
      name "stop_self"
      description "Request graceful termination of this agent"

      schema do
        attribute :reason, :term, description: "Reason for stopping", default: :normal
      end
    end

    def run(%Jido.Signal{data: %{reason: reason}}, _slice, _opts, _ctx) do
      directive = Directives.stop(reason)
      {:ok, %{stopping: true, reason: reason}, [directive]}
    end
  end

  defmodule StopChild do
    @moduledoc """
    Request graceful termination of a tracked child agent.

    ## Schema

    - `tag` - Tag of the child to stop (required)
    - `reason` - Reason for stopping (default: :normal)

    ## Example

        {"coordinator.stop_worker", Aikido.Actions.Lifecycle.StopChild}

        {Aikido.Actions.Lifecycle.StopChild, %{tag: :worker_1, reason: :shutdown}}
    """
    use Aikido.Action

    action do
      name "stop_child"
      description "Request graceful termination of a child agent"

      schema do
        attribute :tag, :atom, description: "Tag of child to stop", allow_nil?: false
        attribute :reason, :term, description: "Reason for stopping", default: :normal
      end
    end

    def run(%Jido.Signal{data: %{tag: tag, reason: reason}}, _slice, _opts, _ctx) do
      directive = Directives.stop_child(tag, reason)
      {:ok, %{stopping_child: tag, reason: reason}, [directive]}
    end
  end
end
