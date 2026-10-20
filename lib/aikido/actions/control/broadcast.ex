defmodule Aikido.Actions.Control.Broadcast do
  @moduledoc """
  Pure reducer for a PubSub broadcast request.

  Accepts `topic`, `signal_type`, `payload` and `source`; preserves `state`
  and returns an `Emit` directive with PubSub dispatch.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    topic = input.arguments[:topic]
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    source = input.arguments[:source]
    signal = %Jido.Signal{id: nil, type: type, data: payload, source: source}
    directive = Aikido.Directives.emit(signal, {:pubsub, topic: topic})
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [directive])
  end
end
