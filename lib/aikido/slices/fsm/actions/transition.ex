defmodule Aikido.Slices.FSM.Actions.Transition do
  @moduledoc """
  Pure reducer for a finite-state machine transition to `to`.

  Checks the supplied slice's transition map, then returns updated state, history
  and terminal status without directives. Disallowed transitions return an error.
  """
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    to = input.arguments.to
    from = Map.fetch!(slice, :state)
    transitions = Map.get(slice, :transitions, %{})
    allowed = Map.get(transitions, from, [])

    if to in allowed do
      terminal_states = Map.get(slice, :terminal_states, [])
      history = Map.get(slice, :history, []) ++ [%{from: from, to: to}]
      new_slice = %{slice | state: to, history: history, terminal?: to in terminal_states}
      Aikido.Types.ActionResult.new(state: new_slice, directives: [])
    else
      {:error, "invalid FSM transition from #{inspect(from)} to #{inspect(to)}"}
    end
  end
end
