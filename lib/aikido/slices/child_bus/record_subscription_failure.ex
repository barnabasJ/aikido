defmodule Aikido.Slices.ChildBus.RecordSubscriptionFailure do
  @moduledoc "Cascade action invoked by the `\"child_bus.subscribe_failed\"` signal\nthat the subscribe-child directive casts when\n`Jido.Signal.Bus.subscribe/3` returns `{:error, reason}`.\n\nAppends `%{path: …, reason: …, at: …}` to\n`slice.failed_subscriptions[tag]` so the gap is observable in slice\nstate instead of being silently swallowed by a `Logger.warning`.\n"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  @persist {:aikido_action_metadata,
            %{
              name: "child_bus_record_subscription_failure",
              description: "Record a child-bus subscription that failed at the bus."
            }}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      argument :tag, :term, allow_nil?: false
      argument :path, :string, allow_nil?: false
      argument :reason, :term, allow_nil?: false
      argument :child_module, :atom, allow_nil?: true
      description "Record a child-bus subscription that failed at the bus."

      run fn input, _context ->
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
      end
    end
  end

  defp reduce(%Jido.Signal{data: %{tag: tag, path: path, reason: reason}}, slice, _opts, _ctx) do
    failures = Map.get(slice, :failed_subscriptions, %{})
    entry = %{path: path, reason: reason, at: System.monotonic_time(:millisecond)}
    next = Map.update(failures, tag, [entry], &[entry | &1])
    {:ok, Map.put(slice, :failed_subscriptions, next), []}
  end
end
