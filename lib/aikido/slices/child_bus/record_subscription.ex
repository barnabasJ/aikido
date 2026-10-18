defmodule Aikido.Slices.ChildBus.RecordSubscription do
  @moduledoc "Cascade action invoked by the `\"child_bus.subscribed\"` signal that\nthe subscribe-child directive casts back to the\nagent on a successful `Jido.Signal.Bus.subscribe/3` call.\n\nAppends the new `sub_id` to `slice.subscriptions[tag]` so that\n`Aikido.Slices.ChildBus.AutoUnsubscribeChild` can find it on\n`aikido.agent.child.exit`.\n"
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  @persist {:aikido_action_metadata,
            %{
              name: "child_bus_record_subscription",
              description: "Record a successful child-bus subscription's sub_id."
            }}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      argument :tag, :term, allow_nil?: false
      argument :sub_id, :term, allow_nil?: false
      argument :path, :string, allow_nil?: true
      description "Record a successful child-bus subscription's sub_id."

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

  defp reduce(%Jido.Signal{data: %{tag: tag, sub_id: sub_id}}, slice, _opts, _ctx) do
    current = Map.get(slice, :subscriptions, %{})
    existing = Map.get(current, tag, [])
    next = Map.put(current, tag, [sub_id | existing])
    {:ok, Map.put(slice, :subscriptions, next), []}
  end
end
