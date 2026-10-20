defmodule Aikido.Signals.Memory.Ensure do
  @moduledoc "Typed payload for `aikido.memory.ensure`."
  use Aikido.Signal

  signal do
    type "aikido.memory.ensure"

    schema do
      attribute :metadata, :map, description: "Optional metadata for new memory.", default: %{}

      attribute :id, :string, description: "Optional explicit memory id."
    end
  end
end
