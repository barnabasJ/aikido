defmodule Aikido.Slices.FSM.Initialize do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    state =
      Ash.Changeset.get_attribute(changeset, :state) ||
        Ash.Changeset.get_attribute(changeset, :initial_state)

    terminal =
      Ash.Changeset.get_attribute(changeset, :terminal?) ||
        state in Ash.Changeset.get_attribute(changeset, :terminal_states)

    changeset
    |> Ash.Changeset.change_attribute(:state, state)
    |> Ash.Changeset.change_attribute(:terminal?, terminal)
  end
end
