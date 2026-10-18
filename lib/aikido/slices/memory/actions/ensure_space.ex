defmodule Aikido.Slices.Memory.Actions.EnsureSpace do
  @moduledoc """
  Ensures a named space exists with the supplied default data. The data
  shape selects the space kind: a `map` produces a key-value space, a
  `list` produces an ordered list space. No-op when the space already
  exists.
  """

  use Aikido.Action

  alias Aikido.Slices.Memory.State

  action do
    name "memory_ensure_space"
    description "Create a space with default data if missing."

    schema do
      attribute :space, :atom, description: "Space name to ensure.", allow_nil?: false

      attribute :default, Aikido.Types.Union,
        description: "Default data for the new space (map → kv, list → list).",
        default: %{},
        constraints: [
          types: [[type: :map, constraints: []], [type: {:array, :term}, constraints: []]]
        ]
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{space: name, default: default}}, slice, _opts, _ctx) do
    memory = ensure_memory(slice)
    {:ok, State.ensure_space(memory, name, default), []}
  end

  defp ensure_memory(%State{} = memory) do
    memory
  end

  defp ensure_memory(_) do
    State.new()
  end
end
