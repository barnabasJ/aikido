defmodule Aikido.Slices.Todo.Actions.Remove do
  @moduledoc "Removes an existing todo and emits its removal to the owning agent."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.Todo.Items

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    id = input.arguments.id

    if Items.find(input) do
      Items.commit(input, Enum.reject(state.items, &(&1.id == id)), %{id: id, removed: true})
    else
      {:error, "Unknown todo ID"}
    end
  end
end
