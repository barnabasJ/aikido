defmodule Aikido.Slices.FSM.Transition do
  @moduledoc """
  Transitions the FSM slice to a new state.

  Triggered by a `aikido.fsm.transition` signal with `data: %{to: "<next>"}`.
  Validates the requested transition against `slice.transitions`, appends
  a `%{from:, to:}` entry to `slice.history`, and flips `terminal?` if the
  new state is in `slice.terminal_states`.
  """
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
  @persist {:aikido_action_metadata, %{name: "fsm_transition"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      argument :to, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]
      run Aikido.Slices.FSM.Transition.Implementation
    end
  end
end
