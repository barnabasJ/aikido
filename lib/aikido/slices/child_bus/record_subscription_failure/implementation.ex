defmodule Aikido.Slices.ChildBus.RecordSubscriptionFailure.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    tag = input.arguments[:tag]
    path = input.arguments[:path]
    reason = input.arguments[:reason]
    slice = input.arguments.state
    failures = Map.get(slice, :failed_subscriptions, %{})
    entry = %{path: path, reason: reason, at: System.monotonic_time(:millisecond)}
    next = Map.update(failures, tag, [entry], &[entry | &1])
    Aikido.ActionResult.new(state: Map.put(slice, :failed_subscriptions, next), directives: [])
  end
end
