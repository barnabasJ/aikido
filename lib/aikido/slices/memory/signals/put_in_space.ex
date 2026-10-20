defmodule Aikido.Slices.Memory.Signals.PutInSpace do
  @moduledoc "Typed payload for `aikido.memory.put_in_space`."
  use Aikido.Signal

  signal do
    type "aikido.memory.put_in_space"

    schema do
      attribute :space, :atom do
        description "Map space name."
        allow_nil? false
      end

      attribute :key, :term do
        description "Key to set."
        allow_nil? false
      end

      attribute :value, :term do
        description "Value to associate with `key`."
        allow_nil? false
      end
    end
  end
end
