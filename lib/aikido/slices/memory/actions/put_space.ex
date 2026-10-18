defmodule Aikido.Slices.Memory.Actions.PutSpace do
  @moduledoc """
  Stores a `%Aikido.Slices.Memory.Space{}` at the named key, replacing any existing
  space and bumping the container revision. Materializes the slice via
  `Aikido.Slices.Memory.State.new/0` when it has not been initialized yet.
  """

  use Aikido.Action

  alias Aikido.Slices.Memory.Space
  alias Aikido.Slices.Memory.State

  action do
    name "memory_put_space"
    description "Store a space wholesale at the named key."

    schema do
      attribute :space, :atom, description: "Space name to set.", allow_nil?: false

      attribute :value, :term,
        description: "%Aikido.Slices.Memory.Space{} to install at the named key.",
        allow_nil?: false
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, value: %Space{} = space}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, State.put_space(memory, name, space), []}
  end

  defp ensure_memory(%State{} = memory) do
    memory
  end

  defp ensure_memory(_) do
    State.new()
  end
end
