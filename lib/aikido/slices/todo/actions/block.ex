defmodule Aikido.Slices.Todo.Actions.Block do
  @moduledoc "Blocks an existing todo with the supplied reason while preserving completed items."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.Todo.Items

  @impl true
  def run(input, _opts, _context) do
    case Items.find(input) do
      nil -> {:error, "Unknown todo ID"}
      %{status: :completed} -> Aikido.Types.ActionResult.new(state: input.arguments.state)
      item -> Items.replace(input, %{item | status: :blocked, reason: input.arguments.reason})
    end
  end
end
