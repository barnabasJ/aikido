defmodule Aikido.Signals.Memory.EnsureSpace do
  @moduledoc "Typed payload for `aikido.memory.ensure_space`."
  use Aikido.Signal

  signal do
    type "aikido.memory.ensure_space"

    schema do
      attribute :space, :atom, description: "Space name to ensure.", allow_nil?: false

      attribute :default, :union,
        description: "Default data for the new space (map → kv, list → list).",
        default: %Ash.Union{type: :kv, value: %{}},
        constraints: [
          types: [kv: [type: :map], list: [type: {:array, :term}]]
        ]
    end
  end
end
