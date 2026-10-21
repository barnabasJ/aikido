defmodule Aikido.FSM.Slice do
  @moduledoc """
  Finite-state-machine slice.

  An agent that mounts `Aikido.FSM.Slice` gains an `:fsm` slice on
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
        slice :fsm, Aikido.FSM.Slice,
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
    extensions: [Aikido.Slice.Extension]

  actions do
    create :create do
      primary? true
      accept :*
      change Aikido.FSM.Changes.Initialize
    end
  end

  slice do
    name "fsm"

    schema do
      attribute :state, :string do
        description "Current state selected from the configured finite-state-machine transitions."
        public? true
        allow_nil? true
        constraints trim?: false, allow_empty?: true
      end

      attribute :history, {:array, :term} do
        description "Successful transitions in chronological order, including their source and destination."
        public? true
        allow_nil? false
        default []
      end

      attribute :terminal?, :boolean do
        description "Whether the current state belongs to the configured terminal states."
        public? true
        allow_nil? true
      end

      attribute :initial_state, :string do
        description "State selected when no explicit current state is provided at initialization."
        public? true
        allow_nil? false
        default @default_initial_state
        constraints trim?: false, allow_empty?: true
      end

      attribute :transitions, :map do
        description "Allowed destination states indexed by their source state."
        public? true
        allow_nil? false
        default @default_transitions
      end

      attribute :terminal_states, {:array, :string} do
        description "State names that mark the finite-state machine as terminal."
        public? true
        allow_nil? false
        default @default_terminal_states
        constraints items: [trim?: false, allow_empty?: true]
      end
    end

    route Aikido.FSM.Signals.Transition, Aikido.FSM.Actions.Transition
  end
end
