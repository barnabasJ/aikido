defmodule Aikido.Actions.Scheduling.ScheduleTimeout do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    timeout = input.arguments[:timeout_ms]
    id = input.arguments[:timeout_id]
    type = input.arguments[:signal_type]

    signal =
      struct!(Jido.Signal, id: nil, type: type, data: %{timeout_id: id}, source: "/timeout")

    directive = Aikido.Directives.schedule(timeout, signal)

    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [directive]
    )
  end
end
