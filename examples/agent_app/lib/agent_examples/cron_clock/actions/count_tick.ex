defmodule AgentExamples.CronClock.Actions.CountTick do
  @moduledoc "Count a scheduled tick only while the recurring clock is enabled."
  use Ash.Resource.Actions.Implementation

  def run(input, _opts, _context) do
    state = input.arguments.state

    Aikido.Types.ActionResult.new(
      changes: %{count: state.count + if(state.enabled, do: 1, else: 0)}
    )
  end
end
