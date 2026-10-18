defmodule Aikido.Slices.ChildBus.RecordSubscriptionFailure do
  @moduledoc """
  Cascade action invoked by the `"child_bus.subscribe_failed"` signal
  that the subscribe-child directive casts when
  `Jido.Signal.Bus.subscribe/3` returns `{:error, reason}`.

  Appends `%{path: …, reason: …, at: …}` to
  `slice.failed_subscriptions[tag]` so the gap is observable in slice
  state instead of being silently swallowed by a `Logger.warning`.
  """

  use Aikido.Action

  action do
    name "child_bus_record_subscription_failure"
    description "Record a child-bus subscription that failed at the bus."

    schema do
      attribute :tag, :term, allow_nil?: false
      attribute :path, :string, allow_nil?: false
      attribute :reason, :term, allow_nil?: false
      attribute :child_module, :atom, allow_nil?: true
    end
  end

  def run(%Jido.Signal{data: %{tag: tag, path: path, reason: reason}}, slice, _opts, _ctx) do
    failures = Map.get(slice, :failed_subscriptions, %{})
    entry = %{path: path, reason: reason, at: System.monotonic_time(:millisecond)}
    next = Map.update(failures, tag, [entry], &[entry | &1])
    {:ok, Map.put(slice, :failed_subscriptions, next), []}
  end
end
