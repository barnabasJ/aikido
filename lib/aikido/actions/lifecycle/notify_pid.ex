defmodule Aikido.Actions.Lifecycle.NotifyPid do
  @moduledoc """
  Pure reducer that prepares a notification for `target_pid`.

  Returns the supplied `state` and an `Emit` directive using `signal_type`,
  `payload`, `source` and the requested `delivery_mode`.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    pid = input.arguments[:target_pid]
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    source = input.arguments[:source]
    mode = input.arguments[:delivery_mode]
    signal = %Jido.Signal{id: nil, type: type, data: payload, source: source}
    directive = Aikido.Directives.emit_to_pid(signal, pid, delivery_mode: mode)
    Aikido.Types.ActionResult.new(state: input.arguments.state, directives: [directive])
  end
end
