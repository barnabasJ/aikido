defmodule Aikido.AgentServer.State do
  @moduledoc """
  Internal state for AgentServer GenServer.

  > #### Internal Module {: .warning}
  > This module is internal to the AgentServer implementation. Its API may
  > change without notice. Use `Aikido.AgentServer.state/3` with a selector
  > to retrieve a projection of state.

  This struct holds all runtime state for an agent instance including
  the agent itself, subscriptions, and configuration.
  Parent and child bindings live in the mounted ownership slice.

  Signal processing runs inline within the triggering handler; the Erlang
  mailbox is the only queue.
  """

  alias Aikido.AgentServer.Options

  @type status :: Aikido.AgentServer.Types.Status.t()

  use Ash.TypedStruct

  typed_struct do
    field :sync, Aikido.Durable.SyncPolicy do
      description "DurableServer synchronization policy used by this agent and inherited by spawned children."
      default %Aikido.Durable.SyncPolicy{}
      allow_nil? false
    end

    field :id, :string do
      allow_nil? false
      description "Stable agent identity used for runtime addressing and durable persistence."
      constraints trim?: false, allow_empty?: true
    end

    field :agent_module, :atom do
      allow_nil? false
      description "Ash resource that owns this runtime's state schema and signal actions."
    end

    field :agent, :term do
      allow_nil? false
      description "Currently adopted immutable agent identity and domain state."
    end

    field :status, Aikido.AgentServer.Types.Status do
      allow_nil? false
      default :initializing
      description "Current server status"
    end

    field :skip_schedules, :boolean do
      allow_nil? false
      default false
      description "Skip registering slice schedules"
    end

    field :aikido, :atom do
      allow_nil? false
      description "Aikido instance name (required)"
    end

    field :partition, :term do
      allow_nil? true
      description "Logical partition within the Aikido instance"
    end

    field :middleware_chain, :term do
      allow_nil? true
      description "Composed middleware chain function (Signal, ctx -> {ctx, dirs})"
    end

    field :signal_router, :term do
      allow_nil? true
      description "Aikido.Signal.Router for signal routing"
    end

    field :durable_server, :atom do
      description "DurableServer supervisor"
    end

    field :durable_key, :term do
      description "Logical DurableServer key"
    end

    field :signal_subscribers, :map do
      allow_nil? false
      default %{}

      description "Map of sub_ref => %{pattern_compiled, selector, target, monitor_ref, once} for subscribe"
    end

    field :ready_waiters, :map do
      allow_nil? false
      default %{}
      description "Map of ref => pid waiting on lifecycle.ready"
    end

    field :debug, :boolean do
      allow_nil? false
      default false
      description "Whether debug mode is enabled"
    end

    field :debug_events, {:array, :term} do
      allow_nil? false
      default []
      description "Debug events retained up to the configured debug_max_events capacity."
    end

    field :debug_max_events, :integer do
      allow_nil? false
      default 500
      description "Max debug events in ring buffer"
    end
  end

  @type t :: %__MODULE__{}

  @doc """
  Creates a new State from validated Options, agent module, and agent struct.

  Partition remains runtime configuration. Parent options are applied through
  the ownership slice's startup action after the signal router is built.

  ## Options

  - `:middleware_chain` — composed middleware chain built by AgentServer's
    `init/1` (a 2-arity function `(Signal.t, ctx -> {ctx, [directive]})`). Stored
    on `%State{}` so signal processing can invoke it without rebuilding.
  """
  @spec from_options(Options.t(), module(), struct(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_options(%Options{} = opts, agent_module, agent, extra \\ []) do
    opts
    |> Map.from_struct()
    |> Map.drop([:parent, :on_parent_death])
    |> Map.merge(%{
      agent_module: agent_module,
      agent: agent,
      middleware_chain: Keyword.get(extra, :middleware_chain),
      debug_max_events: Aikido.Telemetry.Config.debug_max_events(opts.aikido)
    })
    |> new()
  end

  @doc """
  Records a debug event if debug mode is enabled.

  Events are retained up to the configured `debug_max_events` capacity
  (default: 500 entries).
  Each event includes a monotonic timestamp for relative timing.
  """
  @spec record_debug_event(t(), atom(), map()) :: t()
  def record_debug_event(%__MODULE__{} = state, type, data) do
    if state.debug || Aikido.Debug.enabled?(state.aikido) do
      event = %{
        at: System.monotonic_time(:millisecond),
        type: type,
        data: data,
        aikido_instance: state.aikido,
        aikido_partition: state.partition
      }

      new_events = Enum.take([event | state.debug_events], state.debug_max_events)
      %{state | debug_events: new_events}
    else
      state
    end
  end

  @doc """
  Returns recent debug events, newest first.

  ## Options

  - `:limit` - Maximum number of events to return (default: all)
  """
  @spec get_debug_events(t(), keyword()) :: [map()]
  def get_debug_events(%__MODULE__{debug_events: events}, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    case limit do
      nil -> events
      n when is_integer(n) and n > 0 -> Enum.take(events, n)
      _ -> events
    end
  end
end
