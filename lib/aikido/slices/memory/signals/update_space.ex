defmodule Aikido.Slices.Memory.Signals.UpdateSpace do
  @moduledoc "Typed payload for `aikido.memory.update_space`."
  use Aikido.Signal

  signal do
    type "aikido.memory.update_space"

    schema do
      attribute :space, :atom do
        description "Space name to update."
        allow_nil? false
      end

      attribute :value, Aikido.Slices.Memory.Space do
        description "Replacement %Aikido.Slices.Memory.Space{} value."
        allow_nil? false
      end
    end
  end
end
