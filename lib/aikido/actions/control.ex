defmodule Aikido.Actions.Control do
  @moduledoc "Base actions for control flow and signal handling.\n\nThese actions provide common patterns for:\n- Cancellation handling\n- Signal forwarding\n- No-op acknowledgment\n\n## Usage\n\n    use Aikido.Agent\n\n    agent do\n      name \"my_agent\"\n    end\n\n    signal_routes do\n      route \"aikido.agent.cancel\", Aikido.Actions.Control.Cancel\n      route \"proxy.forward\", Aikido.Actions.Control.Forward\n    end\n"
  alias Aikido.Directives
  alias Jido.Signal

  defmodule Cancel do
    @moduledoc "Handle cancellation requests.\n\nSets the agent status to `:failed` with a cancellation error.\nThis is the standard handler for the `aikido.agent.cancel` signal.\n\n## Schema\n\n- `reason` - Cancellation reason (default: :cancelled)\n\n## Example\n\n    # Standard cancellation route\n    {\"aikido.agent.cancel\", Aikido.Actions.Control.Cancel}\n"
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "cancel", description: "Handle cancellation requests"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:reason, :term, description: "Cancellation reason", default: :cancelled)
        description("Handle cancellation requests")

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
      {:ok, %{status: :failed, error: {:cancelled, reason}}, []}
    end
  end

  defmodule Noop do
    @moduledoc "No-operation action that acknowledges a signal without changes.\n\nUseful for:\n- Explicitly handling signals that need no action\n- Testing and debugging signal routing\n- Placeholder routes during development\n\n## Example\n\n    # Acknowledge but ignore certain signals\n    {\"system.ping\", Aikido.Actions.Control.Noop}\n"
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "noop", description: "No-operation, acknowledges signal without changes"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        description("No-operation, acknowledges signal without changes")

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

    defp reduce(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, []}
    end
  end

  defmodule Forward do
    @moduledoc "Forward a signal to another agent.\n\nRe-emits the current signal (or a transformed version) to a target process.\n\n## Schema\n\n- `target_pid` - PID to forward signal to (required)\n- `signal_type` - Optional new signal type (uses original if nil)\n- `payload` - Optional new payload (uses original if nil)\n- `source` - Optional new source (appends \"/forwarded\" if nil)\n\n## Example\n\n    # Forward to a worker pool\n    {Aikido.Actions.Control.Forward, %{target_pid: worker_pid}}\n\n    # Transform and forward\n    {Aikido.Actions.Control.Forward, %{\n      target_pid: processor_pid,\n      signal_type: \"process.request\"\n    }}\n"
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
             data: %{target_pid: pid, signal_type: type, payload: payload, source: source}
           } = original,
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
    @moduledoc "Broadcast a signal to multiple targets via PubSub.\n\n## Schema\n\n- `topic` - PubSub topic to broadcast to (required)\n- `signal_type` - Signal type to broadcast (required)\n- `payload` - Signal payload data (default: %{})\n- `source` - Signal source path (default: \"/broadcast\")\n\n## Example\n\n    {Aikido.Actions.Control.Broadcast, %{\n      topic: \"workers\",\n      signal_type: \"work.available\",\n      payload: %{task_id: \"123\"}\n    }}\n"
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
    @moduledoc "Reply to the source of the current signal.\n\nExtracts the source PID from the incoming signal and sends a reply.\nRequires the original signal to have a `reply_to` field in its data\nor a parseable source containing a PID reference.\n\n## Schema\n\n- `signal_type` - Reply signal type (required)\n- `payload` - Reply payload data (default: %{})\n\n## Example\n\n    # Handle a request and reply\n    use Aikido.Agent\n\n    agent do\n      name \"query_agent\"\n    end\n\n    signal_routes do\n      route \"query.request\", MyQueryHandler\n    end\n\n    # In handler, use Reply action\n    {Aikido.Actions.Control.Reply, %{\n      signal_type: \"query.response\",\n      payload: %{result: data}\n    }}\n"
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    @persist {:aikido_action_metadata,
              %{name: "reply", description: "Reply to the signal source"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)
        argument(:signal_type, :string, description: "Reply signal type", allow_nil?: false)
        argument(:payload, :map, description: "Reply payload", default: %{})
        description("Reply to the signal source")

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
