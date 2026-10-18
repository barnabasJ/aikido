defmodule Aikido.Actions.Control.Broadcast.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    topic = input.arguments[:topic]
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    source = input.arguments[:source]
    signal = Jido.Signal.new!(type, payload, source: source)
    directive = Aikido.Directives.emit(signal, {:pubsub, topic: topic})
    Aikido.ActionResult.new(state: %{broadcast_to: topic}, directives: [directive])
  end
end
