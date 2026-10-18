defmodule Aikido.Actions.Scheduling.ScheduleTimeout.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    timeout = input.arguments[:timeout_ms]
    id = input.arguments[:timeout_id]
    type = input.arguments[:signal_type]
    signal = Jido.Signal.new!(type, %{timeout_id: id}, source: "/timeout")
    directive = Aikido.Directives.schedule(timeout, signal)

    Aikido.ActionResult.new(
      state: %{timeout_set: id, expires_in_ms: timeout},
      directives: [directive]
    )
  end
end
