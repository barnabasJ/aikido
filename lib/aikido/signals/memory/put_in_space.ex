defmodule Aikido.Signals.Memory.PutInSpace do
  @moduledoc "Typed payload for `aikido.memory.put_in_space`."
  use Aikido.Signal

  signal do
    type "aikido.memory.put_in_space"

    schema do
      attribute :space, :atom, description: "Map space name.", allow_nil?: false

      attribute :key, :term, description: "Key to set.", allow_nil?: false

      attribute :value, :term, description: "Value to associate with `key`.", allow_nil?: false
    end
  end
end
