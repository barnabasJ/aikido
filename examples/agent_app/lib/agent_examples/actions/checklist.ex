defmodule AgentExamples.Actions.Checklist do
  use Aikido.Action

  action do
    name "checklist_item"

    schema do
      attribute :item, :string, allow_nil?: false
    end
  end

  @impl true
  def run(%{type: "checklist.add", data: %{item: item}}, state, _opts, _context) do
    {:ok, %{state | items: state.items ++ [item]}, []}
  end

  def run(%{type: "checklist.complete", data: %{item: item}}, state, _opts, _context) do
    if item in state.items do
      {:ok, %{state | items: List.delete(state.items, item), completed: state.completed + 1}, []}
    else
      {:error, :unknown_item}
    end
  end
end
