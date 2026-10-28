defmodule Aikido.Agent.Changes.ApplyState do
  @moduledoc "Applies proposed attributes through native Ash casting and constraints."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attributes(
      changeset,
      Ash.Changeset.get_argument(changeset, :changes)
    )
  end
end
