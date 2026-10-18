defmodule Aikido.Slices.Memory.Actions.UpdateSpace do
  @moduledoc """
  Replaces an existing space's value while bumping its revision.

  Unlike `Aikido.Slices.Memory.Actions.PutSpace`, this action raises when the named
  space is not present — it is the wire-level analogue of
  `Aikido.Slices.Memory.State.update_space/4` for a value-shaped (rather than function-shaped)
  signal payload.
  """

  use Aikido.Action

  alias Aikido.Slices.Memory.Space
  alias Aikido.Slices.Memory.State

  action do
    name "memory_update_space"
    description "Replace the value of an existing space."

    schema do
      attribute :space, :atom, description: "Space name to update.", allow_nil?: false

      attribute :value, :term,
        description: "Replacement %Aikido.Slices.Memory.Space{} value.",
        allow_nil?: false
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, value: %Space{} = new_space}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, State.update_space(memory, name, fn _existing -> new_space end), []}
  end

  defp ensure_memory(%State{} = memory) do
    memory
  end

  defp ensure_memory(_) do
    State.new()
  end
end
