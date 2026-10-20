defmodule Aikido.Signals.Memory.AppendToSpace do
  @moduledoc "Typed payload for `aikido.memory.append_to_space`."
  use Aikido.Signal

  signal do
    type "aikido.memory.append_to_space"

    schema do
      attribute :space, :atom, description: "List space name.", allow_nil?: false

      attribute :item, :term, description: "Item to append.", allow_nil?: false
    end
  end
end
