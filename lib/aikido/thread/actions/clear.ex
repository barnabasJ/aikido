defmodule Aikido.Thread.Actions.Clear do
  @moduledoc "Clears thread entries using the input signal timestamp."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    thread = input.arguments.state

    Aikido.Types.ActionResult.new(
      changes: %{
        entries: [],
        rev: thread.rev + 1,
        updated_at: Aikido.Signal.timestamp(get_in(input.context, [:aikido, :signal])),
        stats: %{thread.stats | entry_count: 0}
      }
    )
  end
end
