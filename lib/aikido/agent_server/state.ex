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

  require Logger

  alias Aikido.AgentServer.{ChildInfo, Options, ParentRef}
  alias Aikido.AgentServer.State.Lifecycle, as: LifecycleState

  @type status :: :initializing | :idle | :stopping

  use Ash.TypedStruct

  typed_struct do
    field :id, :string,
      allow_nil?: false,
      description: "Instance ID",
      constraints: [trim?: false, allow_empty?: true]

    field :agent_module, :atom, allow_nil?: false, description: "Agent module"
    field :agent, :term, allow_nil?: false, description: "The Aikido.Agent struct"

    field :status, :atom,
      allow_nil?: false,
      default: :initializing,
      description: "Current server status"

    field :parent, :term, allow_nil?: true, description: "Parent reference"

    field :orphaned_from, :term,
      allow_nil?: true,
      description: "Former parent reference after orphaning"

    field :children, :map,
      allow_nil?: false,
      default: %{},
      description: "Map of tag => ChildInfo"

    field :on_parent_death, :atom,
      allow_nil?: false,
      default: :stop,
      description: "Behavior on parent death"

    field :cron_jobs, :map,
      allow_nil?: false,
      default: %{},
      description: "Map of job_id => scheduler job name"

    field :cron_monitors, :map,
      allow_nil?: false,
      default: %{},
      description: "Map of job_id => monitor_ref for cron jobs"

    field :cron_monitor_refs, :map,
      allow_nil?: false,
      default: %{},
      description: "Map of monitor_ref => job_id for cron jobs"

    field :cron_restart_attempts, :map,
      allow_nil?: false,
      default: %{},
      description: "Map of job_id => restart attempt count for cron jobs"

    field :cron_restart_timers, :map,
      allow_nil?: false,
      default: %{},
      description: "Map of job_id => timer_ref for cron restarts"

    field :cron_restart_timer_refs, :map,
      allow_nil?: false,
      default: %{},
      description: "Map of timer_ref => job_id for cron restarts"

    field :cron_specs, :map,
      allow_nil?: false,
      default: %{},
      description: "Map of job_id => durable cron registration spec"

    field :cron_runtime_specs, :map,
      allow_nil?: false,
      default: %{},
      description: "Map of job_id => runtime cron restart spec"

    field :skip_schedules, :boolean,
      allow_nil?: false,
      default: false,
      description: "Skip registering slice schedules"

    field :aikido, :atom, allow_nil?: false, description: "Aikido instance name (required)"

    field :partition, :term,
      allow_nil?: true,
      description: "Logical partition within the Aikido instance"

    field :default_dispatch, :term, allow_nil?: true, description: "Default dispatch config"

    field :middleware_chain, :term,
      allow_nil?: true,
      description: "Composed middleware chain function (Signal, ctx -> {ctx, dirs})"

    field :registry, :atom, allow_nil?: false, description: "Registry module"
    field :spawn_fun, :term, allow_nil?: true, description: "Custom spawn function"

    field :signal_router, :term,
      allow_nil?: true,
      description: "Jido.Signal.Router for signal routing"

    field :error_count, :integer,
      allow_nil?: false,
      default: 0,
      description: "Count of errors for max_errors policy"

    field :metrics, :map, allow_nil?: false, default: %{}, description: "Runtime metrics"

    field :signal_subscribers, :map,
      allow_nil?: false,
      default: %{},
      description:
        "Map of sub_ref => %{pattern_compiled, selector, dispatch, monitor_ref, once} for subscribe"

    field :ready_waiters, :map,
      allow_nil?: false,
      default: %{},
      description: "Map of ref => pid waiting on lifecycle.ready"

    field :lifecycle, :term,
      allow_nil?: false,
      description: "Lifecycle state (State.Lifecycle.t())"

    field :debug, :boolean,
      allow_nil?: false,
      default: false,
      description: "Whether debug mode is enabled"

    field :debug_events, {:array, :term},
      allow_nil?: false,
      default: [],
      description: "Ring buffer of debug events (max 500)"

    field :debug_max_events, :integer,
      allow_nil?: false,
      default: 500,
      description: "Max debug events in ring buffer"
  end

  defoverridable new!: 1

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
    lifecycle_opts = [
      pool: opts.pool,
      pool_key: opts.pool_key
    ]

    with {:ok, lifecycle} <- LifecycleState.new(lifecycle_opts) do
      attrs = %{
        id: opts.id,
        agent_module: agent_module,
        agent: agent,
        status: :initializing,
        parent: opts.parent,
        orphaned_from: nil,
        children: %{},
        on_parent_death: opts.on_parent_death,
        aikido: opts.aikido,
        partition: opts.partition,
        default_dispatch: opts.default_dispatch,
        middleware_chain: Keyword.get(extra, :middleware_chain),
        registry: opts.registry,
        spawn_fun: opts.spawn_fun,
        cron_jobs: %{},
        cron_monitors: %{},
        cron_monitor_refs: %{},
        cron_restart_attempts: %{},
        cron_restart_timers: %{},
        cron_restart_timer_refs: %{},
        cron_specs: %{},
        cron_runtime_specs: %{},
        skip_schedules: opts.skip_schedules,
        error_count: 0,
        metrics: %{},
        signal_subscribers: %{},
        ready_waiters: %{},
        lifecycle: lifecycle,
        debug: opts.debug,
        debug_events: [],
        debug_max_events: Aikido.Observe.Config.debug_max_events(opts.aikido)
      }

      Ash.Type.apply_constraints(:struct, attrs, __MODULE__.subtype_constraints())
    end
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
  Updates the agent in state.
  """
  @spec update_agent(t(), struct()) :: t()
  def update_agent(%__MODULE__{} = state, agent) do
    %{state | agent: agent}
  end

  @doc """
  Sets the status.
  """
  @spec set_status(t(), status()) :: t()
  def set_status(%__MODULE__{} = state, status)
      when status in [:initializing, :idle, :stopping] do
    %{state | status: status}
  end

  @doc """
  Adds a child to the children map.
  """
  @spec add_child(t(), term(), ChildInfo.t()) :: t()
  def add_child(%__MODULE__{children: children} = state, tag, %ChildInfo{} = child) do
    %{state | children: Map.put(children, tag, child)}
  end

  @doc """
  Removes a child by tag.
  """
  @spec remove_child(t(), term()) :: t()
  def remove_child(%__MODULE__{children: children} = state, tag) do
    %{state | children: Map.delete(children, tag)}
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
  Gets a child by tag.
  """
  @spec get_child(t(), term()) :: ChildInfo.t() | nil
  def get_child(%__MODULE__{children: children}, tag) do
    Map.get(children, tag)
  end

  @doc """
  Increments the error count.
  """
  @spec increment_error_count(t()) :: t()
  def increment_error_count(%__MODULE__{error_count: count} = state) do
    %{state | error_count: count + 1}
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

  @doc """
  Enables or disables debug mode at runtime.
  """
  @spec set_debug(t(), boolean()) :: t()
  def set_debug(%__MODULE__{} = state, enabled) when is_boolean(enabled) do
    %{state | debug: enabled}
  end
end
