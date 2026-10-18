defmodule Aikido.Actions.Scheduling.ScheduleSignal do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    delay = input.arguments[:delay_ms]
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    source = input.arguments[:source]
    signal = Jido.Signal.new!(type, payload, source: source)
    directive = Aikido.Directives.schedule(delay, signal)

    Aikido.ActionResult.new(
      state: %{scheduled_for_ms: delay, signal_type: type},
      directives: [directive]
    )
  end
end
