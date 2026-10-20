defmodule Aikido.Actions.Scheduling.ScheduleSignal do
  @moduledoc """
  Pure reducer that prepares a signal for delivery after `delay_ms`.

  Returns the supplied `state` and a `Schedule` directive carrying `signal_type`,
  `payload` and `source`; the directive creates the runtime timer.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    delay = input.arguments[:delay_ms]
    type = input.arguments[:signal_type]
    payload = input.arguments[:payload]
    source = input.arguments[:source]
    signal = %Jido.Signal{id: nil, type: type, data: payload, source: source}
    directive = Aikido.Directives.schedule(delay, signal)

    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [directive]
    )
  end
end
