defmodule Aikido.FSM.Changes.Initialize do
  @moduledoc "Derives the initial FSM state and terminal flag from its configuration."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    state =
      Ash.Changeset.get_attribute(changeset, :state) ||
        Ash.Changeset.get_attribute(changeset, :initial_state)

    terminal =
      case Ash.Changeset.get_attribute(changeset, :terminal?) do
        nil -> state in Ash.Changeset.get_attribute(changeset, :terminal_states)
        terminal -> terminal
      end

    changeset
    |> Ash.Changeset.change_attribute(:state, state)
    |> Ash.Changeset.change_attribute(:terminal?, terminal)
  end
end
