defmodule Aikido.Actions.Lifecycle do
  alias Aikido.Directives

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
        run(Aikido.Actions.Lifecycle.NotifyParent.Implementation)
      end
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
        run(Aikido.Actions.Lifecycle.NotifyPid.Implementation)
      end
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
        run(Aikido.Actions.Lifecycle.SpawnChild.Implementation)
      end
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
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "stop_self", description: "Request graceful termination of this agent"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:reason, :term, description: "Reason for stopping", default: :normal)
        description("Request graceful termination of this agent")
        run(Aikido.Actions.Lifecycle.StopSelf.Implementation)
      end
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
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "stop_child", description: "Request graceful termination of a child agent"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:tag, :atom, description: "Tag of child to stop", allow_nil?: false)
        argument(:reason, :term, description: "Reason for stopping", default: :normal)
        description("Request graceful termination of a child agent")
        run(Aikido.Actions.Lifecycle.StopChild.Implementation)
      end
    end
  end
end
