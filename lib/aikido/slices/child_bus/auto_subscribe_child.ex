defmodule Aikido.Slices.ChildBus.AutoSubscribeChild do
  @moduledoc """
  Action invoked by `Aikido.Slices.ChildBus` on every `aikido.agent.child.started`
  signal the host agent receives.

  Reads the child's module and pid out of the signal data, pulls the
  target bus out of the `:child_bus` slice, and emits one
  subscribe-child directive per path
  declared by the child's `signal_routes/0`. The directive performs
  the actual `Jido.Signal.Bus.subscribe/3` I/O and casts a
  `"child_bus.subscribed"` (or `"child_bus.subscribe_failed"`) signal
  back to the agent; the cascade actions
  `Aikido.Slices.ChildBus.RecordSubscription` /
  `RecordSubscriptionFailure` settle the result onto the slice. This
  action itself is pure — it returns the slice unchanged and a
  directive list.

  The host agent's `maybe_track_child_started/2`
  still runs on the same signal and is responsible for putting the
  child in `state.children` — this action is purely additive.
  """
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  @persist {:aikido_action_metadata,
            %{
              name: "child_bus_auto_subscribe_child",
              description: "Emit subscribe directives for each of a child's signal_routes."
            }}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      argument :pid, :term, allow_nil?: false
      argument :child_module, :atom, allow_nil?: false
      argument :tag, :term, allow_nil?: false
      argument :parent_id, :string, allow_nil?: true
      argument :child_id, :string, allow_nil?: true
      argument :child_partition, :term, allow_nil?: true
      argument :meta, :map, allow_nil?: true
      description "Emit subscribe directives for each of a child's signal_routes."
      run Aikido.Slices.ChildBus.AutoSubscribeChild.Implementation
    end
  end
end
