defmodule Aikido.Slices.ChildBus.RecordSubscription do
  @moduledoc """
  Cascade action invoked by the `"child_bus.subscribed"` signal that
  the subscribe-child directive casts back to the
  agent on a successful `Jido.Signal.Bus.subscribe/3` call.

  Appends the new `sub_id` to `slice.subscriptions[tag]` so that
  `Aikido.Slices.ChildBus.AutoUnsubscribeChild` can find it on
  `aikido.agent.child.exit`.
  """
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
      run Aikido.Slices.ChildBus.RecordSubscription.Implementation
    end
  end
end
