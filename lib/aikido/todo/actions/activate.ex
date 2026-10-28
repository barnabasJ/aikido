defmodule Aikido.Todo.Actions.Activate do
  @moduledoc "Activates an existing todo while preserving completed items."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Todo.Items

  @impl true
  def run(input, _opts, _context) do
    case Items.find(input) do
      nil -> {:error, "Unknown todo ID"}
      %{status: :completed} -> Aikido.Types.ActionResult.new(changes: nil)
      item -> Items.replace(input, %{item | status: :active})
    end
  end
end
