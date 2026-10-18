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

  alias Aikido.Directives
  alias Jido.Signal

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
    use Aikido.Action

    action do
      name("cancel")
      description("Handle cancellation requests")

      schema do
        attribute(:reason, :term, description: "Cancellation reason", default: :cancelled)
      end
    end

    def run(%Jido.Signal{data: %{reason: reason}}, _slice, _opts, _ctx) do
      {:ok, %{status: :failed, error: {:cancelled, reason}}, []}
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
    use Aikido.Action

    action do
      name("noop")
      description("No-operation, acknowledges signal without changes")

      schema do
      end
    end

    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, []}
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
    use Aikido.Action

    action do
      name("forward")
      description("Forward a signal to another agent")

      schema do
        attribute(:target_pid, :term, description: "Target process PID", allow_nil?: false)
        attribute(:signal_type, :string, description: "New signal type (optional)", default: nil)
        attribute(:payload, :map, description: "New payload (optional)", default: nil)
        attribute(:source, :string, description: "New source (optional)", default: nil)
      end
    end

    def run(
          %Jido.Signal{
            data: %{target_pid: pid, signal_type: type, payload: payload, source: source}
          } =
            original,
          _slice,
          _opts,
          _ctx
        ) do
      final_type = resolve_type(type, original)
      final_payload = resolve_payload(payload, original)
      final_source = resolve_source(source, original)

      out_signal = Signal.new!(final_type, final_payload, source: final_source)
      directive = Directives.emit_to_pid(out_signal, pid)
      {:ok, %{forwarded_to: pid}, [directive]}
    end

    defp resolve_type(type, _original) when is_binary(type) do
      type
    end

    defp resolve_type(nil, %{type: type}) when is_binary(type) do
      type
    end

    defp resolve_type(nil, _original) do
      "forwarded"
    end

    defp resolve_payload(payload, _original) when is_map(payload) do
      payload
    end

    defp resolve_payload(nil, %{data: data}) when is_map(data) do
      data
    end

    defp resolve_payload(nil, _original) do
      %{}
    end

    defp resolve_source(source, _original) when is_binary(source) do
      source
    end

    defp resolve_source(nil, %{source: original_source}) when is_binary(original_source) do
      original_source <> "/forwarded"
    end

    defp resolve_source(nil, _original) do
      "/forwarded"
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
    use Aikido.Action

    action do
      name("broadcast")
      description("Broadcast a signal via PubSub")

      schema do
        attribute(:topic, :string, description: "PubSub topic", allow_nil?: false)

        attribute(:signal_type, :string,
          description: "Signal type to broadcast",
          allow_nil?: false
        )

        attribute(:payload, :map, description: "Signal payload", default: %{})
        attribute(:source, :string, description: "Signal source", default: "/broadcast")
      end
    end

    def run(
          %Jido.Signal{
            data: %{topic: topic, signal_type: type, payload: payload, source: source}
          },
          _slice,
          _opts,
          _ctx
        ) do
      signal = Signal.new!(type, payload, source: source)
      directive = Directives.emit(signal, {:pubsub, topic: topic})
      {:ok, %{broadcast_to: topic}, [directive]}
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
    use Aikido.Action

    action do
      name("reply")
      description("Reply to the signal source")

      schema do
        attribute(:signal_type, :string, description: "Reply signal type", allow_nil?: false)
        attribute(:payload, :map, description: "Reply payload", default: %{})
      end
    end

    def run(
          %Jido.Signal{data: %{signal_type: type, payload: payload}} = input,
          _slice,
          _opts,
          _ctx
        ) do
      case extract_reply_to(input) do
        {:ok, pid} ->
          out = Signal.new!(type, payload, source: "/reply")
          directive = Directives.emit_to_pid(out, pid)
          {:ok, %{replied_to: pid}, [directive]}

        :error ->
          {:ok, %{replied_to: nil, warning: "No reply_to found in signal"}, []}
      end
    end

    defp extract_reply_to(%{data: %{reply_to: pid}}) when is_pid(pid) do
      {:ok, pid}
    end

    defp extract_reply_to(_) do
      :error
    end
  end
end
