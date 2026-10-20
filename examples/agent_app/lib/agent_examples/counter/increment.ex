defmodule AgentExamples.Counter.Increment do
  @moduledoc "Adds the supplied amount to the counter state."
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{state | count: state.count + input.arguments.amount})
  end
end
