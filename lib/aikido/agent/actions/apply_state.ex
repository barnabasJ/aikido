defmodule Aikido.Agent.Actions.ApplyState do
  @moduledoc "Returns the state produced by an actual native update without writing an independent data layer."
  use Ash.Resource.ManualUpdate

  @impl true
  def update(changeset, _opts, _context), do: Ash.Changeset.apply_attributes(changeset)
end
