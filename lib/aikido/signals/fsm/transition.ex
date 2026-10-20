defmodule Aikido.Signals.FSM.Transition do
  @moduledoc "Typed payload for `aikido.fsm.transition`."
  use Aikido.Signal

  signal do
    type "aikido.fsm.transition"

    schema do
      attribute :to, :string do
        description "Destination state requested for the finite-state-machine transition."
        allow_nil? false
        constraints trim?: false, allow_empty?: true
      end
    end
  end
end
