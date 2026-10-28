defmodule AgentExamples.Counter.Actions.Adjust do
  @moduledoc "One native Ash union handles both typed adjustment signals."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    %{state: state, data: %Ash.Union{type: direction, value: %{amount: amount}}} = input.arguments
    delta = if direction == :increase, do: amount, else: -amount
    Aikido.Types.ActionResult.new(changes: %{count: state.count + delta})
  end
end
