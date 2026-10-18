defmodule Aikido.Slices.ChildBus.RecordSubscriptionFailure do
  @moduledoc """
  Cascade action invoked by the `"child_bus.subscribe_failed"` signal
  that the subscribe-child directive casts when
  `Jido.Signal.Bus.subscribe/3` returns `{:error, reason}`.

  Appends `%{path: …, reason: …, at: …}` to
  `slice.failed_subscriptions[tag]` so the gap is observable in slice
  state instead of being silently swallowed by a `Logger.warning`.
  """
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
      run Aikido.Slices.ChildBus.RecordSubscriptionFailure.Implementation
    end
  end
end
