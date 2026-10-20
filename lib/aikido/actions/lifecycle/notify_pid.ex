defmodule Aikido.Actions.Lifecycle.NotifyPid do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    pid = input.arguments[:target_pid]
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    source = input.arguments[:source]
    mode = input.arguments[:delivery_mode]
    signal = struct!(Jido.Signal, id: nil, type: type, data: payload, source: source)
    directive = Aikido.Directives.emit_to_pid(signal, pid, delivery_mode: mode)
    Aikido.Types.ActionResult.new(state: %{sent_to: pid}, directives: [directive])
  end
end
