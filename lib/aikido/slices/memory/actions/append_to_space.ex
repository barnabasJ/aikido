defmodule Aikido.Slices.Memory.Actions.AppendToSpace do
  @moduledoc """
  Appends `item` to the end of an ordered (list) space. Raises when the
  named space is missing or not a list space.
  """

  use Aikido.Action

  alias Aikido.Slices.Memory.State

  action do
    name "memory_append_to_space"
    description "Append an item to a list space."

    schema do
      attribute :space, :atom, description: "List space name.", allow_nil?: false
      attribute :item, :term, description: "Item to append.", allow_nil?: false
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, item: item}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, State.append_to_space(memory, name, item), []}
  end

  defp ensure_memory(%State{} = memory) do
    memory
  end

  defp ensure_memory(_) do
    State.new()
  end
end
