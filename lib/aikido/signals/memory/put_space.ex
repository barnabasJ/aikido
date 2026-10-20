defmodule Aikido.Signals.Memory.PutSpace do
  @moduledoc "Typed payload for `aikido.memory.put_space`."
  use Aikido.Signal

  signal do
    type "aikido.memory.put_space"

    schema do
      attribute :space, :atom do
        description "Space name to set."
        allow_nil? false
      end

      attribute :value, Aikido.Slices.Memory.Space do
        description "%Aikido.Slices.Memory.Space{} to install at the named key."
        allow_nil? false
      end
    end
  end
end
