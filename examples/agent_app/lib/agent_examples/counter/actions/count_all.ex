defmodule AgentExamples.Counter.Actions.CountAll do
  @moduledoc "Count every routed signal, including signals without a typed handler."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{state | signals_seen: state.signals_seen + 1})
  end
end
