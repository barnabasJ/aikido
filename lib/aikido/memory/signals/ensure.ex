defmodule Aikido.Memory.Signals.Ensure do
  @moduledoc "Typed payload for `aikido.memory.ensure`."
  use Aikido.Signal

  signal do
    type "aikido.memory.ensure"

    schema do
      attribute :metadata, :map do
        description "Optional metadata for new memory."
        default %{}
      end

      attribute :id, :string do
        description "Optional explicit memory id."
      end
    end
  end
end
