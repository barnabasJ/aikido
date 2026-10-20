defmodule Aikido.AgentServer.State do
  @moduledoc """
  Internal state for AgentServer GenServer.

  > #### Internal Module {: .warning}
  > This module is internal to the AgentServer implementation. Its API may
  > change without notice. Use `Aikido.AgentServer.state/3` with a selector
  > to retrieve a projection of state.

  This struct holds all runtime state for an agent instance including
  the agent itself, hierarchy tracking, and configuration.

  Signal processing runs inline within the triggering handler; the Erlang
  mailbox is the only queue.
  """

  alias Aikido.AgentServer.{ChildInfo, Options, ParentRef}

  @type status :: :initializing | :idle | :stopping

  use Ash.TypedStruct

  typed_struct do
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

    field :status, :atom do
      allow_nil? false
      default :initializing
      description "Current server status"
    end

    field :parent, :term do
      allow_nil? true
      description "Parent reference"
    end

    field :orphaned_from, :term do
      allow_nil? true
      description "Former parent reference after orphaning"
    end

    field :children, :map do
      allow_nil? false
      default %{}
      description "Map of tag => ChildInfo"
    end

    field :on_parent_death, :atom do
      allow_nil? false
      default :stop
      constraints one_of: [:stop, :continue, :emit_orphan]
      description "Behavior on parent death"
    end

    field :cron_jobs, :map do
      allow_nil? false
      default %{}
      description "Map of job_id => scheduler job name"
    end

    field :cron_monitors, :map do
      allow_nil? false
      default %{}
      description "Map of job_id => monitor_ref for cron jobs"
    end

    field :cron_monitor_refs, :map do
      allow_nil? false
      default %{}
      description "Map of monitor_ref => job_id for cron jobs"
    end

    field :cron_restart_attempts, :map do
      allow_nil? false
      default %{}
      description "Map of job_id => restart attempt count for cron jobs"
    end

    field :cron_restart_timers, :map do
      allow_nil? false
      default %{}
      description "Map of job_id => timer_ref for cron restarts"
    end

    field :cron_restart_timer_refs, :map do
      allow_nil? false
      default %{}
      description "Map of timer_ref => job_id for cron restarts"
    end

    field :cron_specs, :map do
      allow_nil? false
      default %{}
      description "Map of job_id => durable cron registration spec"
    end

    field :cron_runtime_specs, :map do
      allow_nil? false
      default %{}
      description "Map of job_id => runtime cron restart spec"
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
      description "Ring buffer of debug events (max 500)"
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

  Runtime identity (`partition`, `parent`, `orphaned_from`) lives only on the
  returned `%State{}`; nothing is mirrored into `agent.state`.

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
    |> Map.merge(%{
      agent_module: agent_module,
      agent: agent,
      middleware_chain: Keyword.get(extra, :middleware_chain),
      debug_max_events: Aikido.Telemetry.Config.debug_max_events(opts.aikido)
    })
    |> new()
  end

  @doc """
  Attaches a parent reference to the runtime.

  Runtime identity lives only on `%State{}`; the agent struct is left
  untouched.
  """
  @spec attach_parent(t(), ParentRef.t()) :: t()
  def attach_parent(%__MODULE__{} = state, %ParentRef{} = parent) do
    %{state | parent: parent, orphaned_from: nil}
  end

  @doc """
  Transitions the runtime into an orphaned state, preserving the former
  parent on `%State{}`.
  """
  @spec orphan_parent(t()) :: t()
  def orphan_parent(%__MODULE__{parent: %ParentRef{} = parent} = state) do
    %{state | parent: nil, orphaned_from: parent}
  end

  def orphan_parent(%__MODULE__{} = state) do
    %{state | parent: nil, orphaned_from: nil}
  end

  @doc """
  Adds a child to the children map.
  """
  @spec add_child(t(), term(), ChildInfo.t()) :: t()
  def add_child(%__MODULE__{children: children} = state, tag, %ChildInfo{} = child) do
    %{state | children: Map.put(children, tag, child)}
  end

  @doc """
  Removes a child by PID.
  """
  @spec remove_child_by_pid(t(), pid()) :: {term() | nil, t()}
  def remove_child_by_pid(%__MODULE__{children: children} = state, pid) do
    case Enum.find(children, fn {_tag, child} -> child.pid == pid end) do
      {tag, _child} ->
        {tag, %{state | children: Map.delete(children, tag)}}

      nil ->
        {nil, state}
    end
  end

  @doc """
  Records a debug event if debug mode is enabled.

  Events are stored in a ring buffer (max 500 entries).
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
