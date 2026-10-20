defmodule Aikido.Signals.FSM.Transition do
  @moduledoc "Typed payload for `aikido.fsm.transition`."
  use Aikido.Signal

  signal do
    type "aikido.fsm.transition"

    schema do
      attribute :to, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]
    end
  end
end
