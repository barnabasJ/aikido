defmodule Aikido.Agent.Commands.Snapshot do
  @moduledoc """
  Returns a live snapshot materialized by native Ash argument casting.

  This private projection action preserves resource attribute types without
  invoking create/update changes, applying defaults or writing a data layer.
  Public inspection and list commands own authorization and supply caller scope.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context), do: {:ok, input.arguments.snapshot}
end
