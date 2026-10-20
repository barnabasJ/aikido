defmodule AgentExamples.Counter.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{state | count: state.count + input.arguments.amount})
  end
end

defmodule AgentExamples.Counter.Adjust do
  @moduledoc "One native Ash union handles both typed adjustment signals."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    %{state: state, data: %Ash.Union{type: direction, value: %{amount: amount}}} = input.arguments
    delta = if direction == :increase, do: amount, else: -amount
    Aikido.Types.ActionResult.new(state: %{state | count: state.count + delta})
  end
end

defmodule AgentExamples.Counter.CountAll do
  @moduledoc "Count every routed signal, including signals without a typed handler."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{state | signals_seen: state.signals_seen + 1})
  end
end
