defmodule Aikido.Signals.Thread.Ensure do
  @moduledoc "Typed payload for `aikido.thread.ensure`."
  use Aikido.Signal

  signal do
    type "aikido.thread.ensure"

    schema do
      attribute :metadata, :map,
        description: "Optional metadata for newly created thread.",
        default: %{}

      attribute :id, :string, description: "Optional explicit thread id."
    end
  end
end
