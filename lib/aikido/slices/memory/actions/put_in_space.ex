defmodule Aikido.Slices.Memory.Actions.PutInSpace do
  @moduledoc """
  Sets `key => value` in a key-value (map) space. Raises when the named
  space is missing or not a map space.
  """

  use Aikido.Action

  alias Aikido.Slices.Memory.State

  action do
    name "memory_put_in_space"
    description "Set a key in a map space."

    schema do
      attribute :space, :atom, description: "Map space name.", allow_nil?: false
      attribute :key, :term, description: "Key to set.", allow_nil?: false
      attribute :value, :term, description: "Value to associate with `key`.", allow_nil?: false
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, key: key, value: value}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, State.put_in_space(memory, name, key, value), []}
  end

  defp ensure_memory(%State{} = memory) do
    memory
  end

  defp ensure_memory(_) do
    State.new()
  end
end
