defmodule Aikido.Slices.FSM do
  @moduledoc """
  Finite-state-machine slice.

  An agent that mounts `Aikido.Slices.FSM` gains an `:fsm` slice on
  `agent.state` containing:

      %{
        state: String.t(),                                    # current state
        history: [%{from: String.t(), to: String.t()}],       # transitions, oldest first
        terminal?: boolean(),
        transitions: %{String.t() => [String.t()]},
        terminal_states: [String.t()],
        initial_state: String.t()
      }

  The slice owns the native Ash `:transition` action and delegates its pure
  transition logic to a separate implementation module.
  Send an `aikido.fsm.transition` signal with `data: %{to: "<next_state>"}` to
  attempt a transition.

  ## Configuration

  Mount inside `agent do …` and pass per-agent transitions and terminal states
  via `options:`:

      use Aikido.Agent

      agent do
        name "my_agent"
        slice :fsm, Aikido.Slices.FSM,
          options: [
            initial_state: "ready",
            transitions: %{
              "ready" => ["working", "done"],
              "working" => ["ready", "done", "errored"],
              "done" => [],
              "errored" => []
            },
            terminal_states: ["done", "errored"]
          ]
      end

  The default transition map allows these transitions:

      %{
        "idle" => ["processing"],
        "processing" => ["idle", "completed", "failed"],
        "completed" => ["idle"],
        "failed" => ["idle"]
      }

  with terminal states `["completed", "failed"]`.
  """

  @default_initial_state "idle"
  @default_transitions %{
    "idle" => ["processing"],
    "processing" => ["idle", "completed", "failed"],
    "completed" => ["idle"],
    "failed" => ["idle"]
  }
  @default_terminal_states ["completed", "failed"]

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Ash.Slice]

  actions do
    create :create do
      primary? true
      accept :*
      change Aikido.Slices.FSM.Initialize
    end

    action :transition, Aikido.Types.ActionResult do
      argument :state, :term, allow_nil?: false
      argument :to, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]
      run Aikido.Slices.FSM.Transition
    end
  end

  slice do
    name "fsm"

    schema do
      attribute :state, :string,
        public?: true,
        allow_nil?: true,
        constraints: [trim?: false, allow_empty?: true]

      attribute :history, {:array, :term}, public?: true, allow_nil?: false, default: []
      attribute :terminal?, :boolean, public?: true, allow_nil?: true

      attribute :initial_state, :string,
        public?: true,
        allow_nil?: false,
        default: @default_initial_state,
        constraints: [trim?: false, allow_empty?: true]

      attribute :transitions, :map,
        public?: true,
        allow_nil?: false,
        default: @default_transitions

      attribute :terminal_states, {:array, :string},
        public?: true,
        allow_nil?: false,
        default: @default_terminal_states,
        constraints: [items: [trim?: false, allow_empty?: true]]
    end

    route "aikido.fsm.transition", :transition
  end
end
