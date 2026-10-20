defmodule Aikido.Signals.Memory.DeleteSpace do
  @moduledoc "Typed payload for `aikido.memory.delete_space`."
  use Aikido.Signal

  signal do
    type "aikido.memory.delete_space"

    schema do
      attribute :space, :atom, description: "Space name to delete.", allow_nil?: false
    end
  end
end
