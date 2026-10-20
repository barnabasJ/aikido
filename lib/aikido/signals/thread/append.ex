defmodule Aikido.Signals.Thread.Append do
  @moduledoc "Typed payload for `aikido.thread.append`."
  use Aikido.Signal

  signal do
    type "aikido.thread.append"

    schema do
      attribute :entry, :union do
        description "Entry map (or list of entry maps) to append."
        allow_nil? false
        constraints types: [entry: [type: :map], entries: [type: {:array, :map}]]
      end
    end
  end
end
