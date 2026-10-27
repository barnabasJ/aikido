defmodule Aikido.Memory.Signals.DeleteFromSpace do
  @moduledoc "Typed payload for `aikido.memory.delete_from_space`."
  use Aikido.Signal

  signal do
    type "aikido.memory.delete_from_space"

    schema do
      attribute :space, :atom do
        description "Map space name."
        allow_nil? false
      end

      attribute :key, :term do
        description "Key to remove."
        allow_nil? false
      end
    end
  end
end
