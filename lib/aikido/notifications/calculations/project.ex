defmodule Aikido.Notifications.Calculations.Project do
  @moduledoc """
  Native aggregate calculation for opted-in notification projections.

  Generated calculation options supply projection metadata. Ash loads each
  resource's own calculation before this module combines the loaded values;
  normal calculation loading retains the caller's native Ash scope.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, opts, _context) do
    opts
    |> Keyword.fetch!(:projections)
    |> Aikido.Notifications.Projection.loads()
  end

  @impl true
  def calculate(records, opts, _context) do
    definitions = Keyword.fetch!(opts, :projections)
    Enum.map(records, &Aikido.Notifications.Projection.project(&1, definitions))
  end
end
