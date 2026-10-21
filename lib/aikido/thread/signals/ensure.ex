defmodule Aikido.Thread.Signals.Ensure do
  @moduledoc "Typed payload for `aikido.thread.ensure`."
  use Aikido.Signal

  signal do
    type "aikido.thread.ensure"

    schema do
      attribute :metadata, :map do
        description "Optional metadata for newly created thread."
        default %{}
      end

      attribute :id, :string do
        description "Optional explicit thread id."
      end
    end
  end
end
