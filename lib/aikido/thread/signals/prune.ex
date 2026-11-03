defmodule Aikido.Thread.Signals.Prune do
  @moduledoc "Typed payload for `aikido.thread.prune`."
  use Aikido.Signal

  signal do
    type "aikido.thread.prune"

    schema do
      attribute :path, :atom do
        description "Source mount receiving this request."
        default :thread
        allow_nil? false
      end

      attribute :through_sequence, :integer do
        description "Last sequence to remove, inclusive."
        allow_nil? false
        constraints min: 0
      end
    end
  end
end
