defmodule Aikido.Slices.ChildBus.RecordSubscription.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    tag = input.arguments[:tag]
    sub_id = input.arguments[:sub_id]
    slice = input.arguments.state
    current = Map.get(slice, :subscriptions, %{})
    existing = Map.get(current, tag, [])
    next = Map.put(current, tag, [sub_id | existing])
    Aikido.ActionResult.new(state: Map.put(slice, :subscriptions, next), directives: [])
  end
end
