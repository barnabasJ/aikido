defmodule Aikido.Slices.Memory.Actions.DeleteSpace do
  @moduledoc """
  Deletes a non-reserved space. Raises `ArgumentError` for reserved spaces
  (`:tasks`, `:world`).
  """

  use Aikido.Action

  alias Aikido.Slices.Memory.State

  action do
    name "memory_delete_space"
    description "Delete a non-reserved space."

    schema do
      attribute :space, :atom, description: "Space name to delete.", allow_nil?: false
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, State.delete_space(memory, name), []}
  end

  defp ensure_memory(%State{} = memory) do
    memory
  end

  defp ensure_memory(_) do
    State.new()
  end
end
