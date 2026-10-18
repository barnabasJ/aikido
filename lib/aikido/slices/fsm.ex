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

  Transitions are driven by signals routed to `Aikido.Slices.FSM.Transition`.
  Send a `aikido.fsm.transition` signal with `data: %{to: "<next_state>"}` to
  attempt a transition.

  ## Configuration

  Mount in `slices do …` and pass per-agent transitions and terminal states
  via `options:`:

      use Aikido.Agent

      agent do
        name "my_agent"
      end

      slices do
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

  The default transition map mirrors the historical FSM strategy:

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

  use Aikido.Slice

  slice do
    name "fsm"

    schema do
      attribute :state, :string, allow_nil?: true, constraints: [trim?: false, allow_empty?: true]
      attribute :history, {:array, :term}, allow_nil?: false, default: []
      attribute :terminal?, :boolean, allow_nil?: true

      attribute :initial_state, :string,
        allow_nil?: false,
        default: @default_initial_state,
        constraints: [trim?: false, allow_empty?: true]

      attribute :transitions, :map, allow_nil?: false, default: @default_transitions

      attribute :terminal_states, {:array, :string},
        allow_nil?: false,
        default: @default_terminal_states,
        constraints: [items: [trim?: false, allow_empty?: true]]
    end

    state_transform {__MODULE__, :seed_runtime_fields, []}
  end

  signal_routes do
    route "aikido.fsm.transition", Aikido.Slices.FSM.Transition
  end

  @doc false
  def default_initial_state do
    @default_initial_state
  end

  @doc false
  def default_transitions do
    @default_transitions
  end

  @doc false
  def default_terminal_states do
    @default_terminal_states
  end

  @doc false
  @spec seed_runtime_fields(map(), keyword() | keyword()) :: {:ok, map()}
  def seed_runtime_fields(slice, _ctx) do
    state = Map.get(slice, :state) || slice.initial_state
    terminal? = Map.get(slice, :terminal?) || state in slice.terminal_states
    {:ok, Map.merge(slice, %{state: state, terminal?: terminal?})}
  end
end
