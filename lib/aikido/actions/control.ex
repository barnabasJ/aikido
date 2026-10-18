defmodule Aikido.Actions.Control do
  @moduledoc """
  Base actions for control flow and signal handling.

  These actions provide common patterns for:
  - Cancellation handling
  - Signal forwarding
  - No-op acknowledgment

  ## Usage

      use Aikido.Agent

      agent do
        name "my_agent"
      end

      signal_routes do
        route "aikido.agent.cancel", Aikido.Actions.Control.Cancel
        route "proxy.forward", Aikido.Actions.Control.Forward
      end
  """

  defmodule Cancel do
    @moduledoc """
    Handle cancellation requests.

    Sets the agent status to `:failed` with a cancellation error.
    This is the standard handler for the `aikido.agent.cancel` signal.

    ## Schema

    - `reason` - Cancellation reason (default: :cancelled)

    ## Example

        # Standard cancellation route
        {"aikido.agent.cancel", Aikido.Actions.Control.Cancel}
    """
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "cancel", description: "Handle cancellation requests"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:reason, :term, description: "Cancellation reason", default: :cancelled)
        description("Handle cancellation requests")
        run(Aikido.Actions.Control.Cancel.Implementation)
      end
    end
  end

  defmodule Noop do
    @moduledoc """
    No-operation action that acknowledges a signal without changes.

    Useful for:
    - Explicitly handling signals that need no action
    - Testing and debugging signal routing
    - Placeholder routes during development

    ## Example

        # Acknowledge but ignore certain signals
        {"system.ping", Aikido.Actions.Control.Noop}
    """
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "noop", description: "No-operation, acknowledges signal without changes"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        description("No-operation, acknowledges signal without changes")
        run(Aikido.Actions.Control.Noop.Implementation)
      end
    end
  end

  defmodule Forward do
    @moduledoc """
    Forward a signal to another agent.

    Re-emits the current signal (or a transformed version) to a target process.

    ## Schema

    - `target_pid` - PID to forward signal to (required)
    - `signal_type` - Optional new signal type (uses original if nil)
    - `payload` - Optional new payload (uses original if nil)
    - `source` - Optional new source (appends "/forwarded" if nil)

    ## Example

        # Forward to a worker pool
        {Aikido.Actions.Control.Forward, %{target_pid: worker_pid}}

        # Transform and forward
        {Aikido.Actions.Control.Forward, %{
          target_pid: processor_pid,
          signal_type: "process.request"
        }}
    """
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "forward", description: "Forward a signal to another agent"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:target_pid, :term, description: "Target process PID", allow_nil?: false)
        argument(:signal_type, :string, description: "New signal type (optional)", default: nil)
        argument(:payload, :map, description: "New payload (optional)", default: nil)
        argument(:source, :string, description: "New source (optional)", default: nil)
        description("Forward a signal to another agent")
        run(Aikido.Actions.Control.Forward.Implementation)
      end
    end
  end

  defmodule Broadcast do
    @moduledoc """
    Broadcast a signal to multiple targets via PubSub.

    ## Schema

    - `topic` - PubSub topic to broadcast to (required)
    - `signal_type` - Signal type to broadcast (required)
    - `payload` - Signal payload data (default: %{})
    - `source` - Signal source path (default: "/broadcast")

    ## Example

        {Aikido.Actions.Control.Broadcast, %{
          topic: "workers",
          signal_type: "work.available",
          payload: %{task_id: "123"}
        }}
    """
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "broadcast", description: "Broadcast a signal via PubSub"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:topic, :string, description: "PubSub topic", allow_nil?: false)

        argument(:signal_type, :string,
          description: "Signal type to broadcast",
          allow_nil?: false
        )

        argument(:payload, :map, description: "Signal payload", default: %{})
        argument(:source, :string, description: "Signal source", default: "/broadcast")
        description("Broadcast a signal via PubSub")
        run(Aikido.Actions.Control.Broadcast.Implementation)
      end
    end
  end

  defmodule Reply do
    @moduledoc """
    Reply to the source of the current signal.

    Extracts the source PID from the incoming signal and sends a reply.
    Requires the original signal to have a `reply_to` field in its data
    or a parseable source containing a PID reference.

    ## Schema

    - `signal_type` - Reply signal type (required)
    - `payload` - Reply payload data (default: %{})

    ## Example

        # Handle a request and reply
        use Aikido.Agent

        agent do
          name "query_agent"
        end

        signal_routes do
          route "query.request", MyQueryHandler
        end

        # In handler, use Reply action
        {Aikido.Actions.Control.Reply, %{
          signal_type: "query.response",
          payload: %{result: data}
        }}
    """
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "reply", description: "Reply to the signal source"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:signal_type, :string, description: "Reply signal type", allow_nil?: false)
        argument(:payload, :map, description: "Reply payload", default: %{})
        description("Reply to the signal source")
        run(Aikido.Actions.Control.Reply.Implementation)
      end
    end
  end
end
