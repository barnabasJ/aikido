defmodule Aikido.Slices.ChildBus.RecordSubscription do
  @moduledoc """
  Cascade action invoked by the `"child_bus.subscribed"` signal that
  the subscribe-child directive casts back to the
  agent on a successful `Jido.Signal.Bus.subscribe/3` call.

  Appends the new `sub_id` to `slice.subscriptions[tag]` so that
  `Aikido.Slices.ChildBus.AutoUnsubscribeChild` can find it on
  `aikido.agent.child.exit`.
  """

  use Aikido.Action

  action do
    name "child_bus_record_subscription"
    description "Record a successful child-bus subscription's sub_id."

    schema do
      attribute :tag, :term, allow_nil?: false
      attribute :sub_id, :term, allow_nil?: false
      attribute :path, :string, allow_nil?: true
    end
  end

  def run(%Jido.Signal{data: %{tag: tag, sub_id: sub_id}}, slice, _opts, _ctx) do
    current = Map.get(slice, :subscriptions, %{})
    existing = Map.get(current, tag, [])
    next = Map.put(current, tag, [sub_id | existing])
    {:ok, Map.put(slice, :subscriptions, next), []}
  end
end
