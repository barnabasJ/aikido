defmodule Aikido.Signals.Memory.UpdateSpace do
  @moduledoc "Typed payload for `aikido.memory.update_space`."
  use Aikido.Signal

  signal do
    type "aikido.memory.update_space"

    schema do
      attribute :space, :atom, description: "Space name to update.", allow_nil?: false

      attribute :value, Aikido.Slices.Memory.Space,
        description: "Replacement %Aikido.Slices.Memory.Space{} value.",
        allow_nil?: false
    end
  end
end
