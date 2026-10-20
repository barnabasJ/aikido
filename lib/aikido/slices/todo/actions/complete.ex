defmodule Aikido.Slices.Todo.Actions.Complete do
  @moduledoc "Records a todo result while preserving an already completed item."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Slices.Todo.Items

  @impl true
  def run(input, _opts, _context) do
    case Items.find(input) do
      nil ->
        {:error, "Unknown todo ID"}

      %{status: :completed} ->
        Aikido.Types.ActionResult.new(state: input.arguments.state)

      item ->
        Items.replace(input, %{
          item
          | status: :completed,
            result: input.arguments[:result],
            reason: nil
        })
    end
  end
end
