defmodule Aikido.Todo.Items do
  @moduledoc "Pure todo collection changes and change-notification descriptors."

  def find(input), do: Enum.find(input.arguments.state.items, &(&1.id == input.arguments.id))

  def append(input, item, effects) do
    item = cast_item(item)

    replace_items_with_change_notification(
      input,
      input.arguments.state.items ++ [item],
      %{id: item.id, item: item},
      effects
    )
  end

  def replace(input, item) do
    item = cast_item(item)

    items =
      Enum.map(input.arguments.state.items, fn existing ->
        if existing.id == item.id, do: item, else: existing
      end)

    replace_items_with_change_notification(input, items, %{id: item.id, item: item})
  end

  @doc "Return revised items and a change signal directed to the owning agent."
  def replace_items_with_change_notification(input, items, changed, effects \\ []) do
    state = input.arguments.state

    signal = %Aikido.Signal{
      id: nil,
      type: "aikido.todo.changed",
      data: changed,
      source: "/aikido"
    }

    Aikido.Types.ActionResult.new(
      state: %{state | items: items, revision: state.revision + 1},
      directives: [
        Aikido.Directives.emit_to_pid(signal, input.context.aikido.agent_pid) | effects
      ]
    )
  end

  @doc "Describe the optional item deadline, correlated with its addition revision."
  def expiration_directives(%{timeout_ms: nil}), do: []

  def expiration_directives(item) do
    [
      Aikido.Directives.schedule(item.timeout_ms, %Aikido.Signal{
        id: nil,
        type: "aikido.todo.expire",
        data: %{id: item.id, revision: item.revision},
        source: "/aikido"
      })
    ]
  end

  defp cast_item(%_{} = item), do: item

  defp cast_item(item),
    do: Aikido.Todo.Item.new!(Map.reject(item, fn {_, value} -> is_nil(value) end))
end
