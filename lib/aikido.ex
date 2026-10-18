defmodule Aikido do
  use Supervisor

  alias Aikido.Agent.WorkerPool
  alias Aikido.Config.Defaults
  alias Aikido.RuntimeStore

  @moduledoc """
  自動 (Aikido) - An autonomous agent framework for Elixir, built for workflows and
  multi-agent systems.

  ## Quick Start

  Create a Aikido supervisor in your application:

      defmodule MyApp.Aikido do
        use Aikido, otp_app: :my_app
      end

  Add to your supervision tree:

      children = [MyApp.Aikido]

  Start and manage agents:

      {:ok, pid} = MyApp.Aikido.start_agent(MyAgent, id: "agent-1")
      pid = MyApp.Aikido.whereis("agent-1")
      agents = MyApp.Aikido.list_agents()
      :ok = MyApp.Aikido.stop_agent("agent-1")

  ## Core Concepts

  Aikido agents are immutable data structures. The core operation is `cmd/2`:

      {agent, directives} = MyAgent.cmd(agent, MyAction)

  - **Agents** — Immutable structs updated via commands
  - **Actions** — Functions that transform agent state (may perform side effects)
  - **Directives** — Descriptions of external effects (signals, processes, etc.)

  ## For Tests

  Use `AikidoTest.Case` for isolation:

      defmodule MyAgentTest do
        use AikidoTest.Case, async: true

        test "agent works", %{aikido: aikido} do
          {:ok, pid} = Aikido.start_agent(aikido, MyAgent)
          # ...
        end
      end

  See `Aikido.Agent` for defining agents and `Aikido.AgentServer` for the
  signal-driven runtime (including the `call/4` and `subscribe/4`
  primitives for coordination).
  """

  @doc """
  Creates a Aikido supervisor module.

  ## Options

    - `:otp_app` - Required. Your application name (e.g., `:my_app`).

  ## Example

      defmodule MyApp.Aikido do
        use Aikido, otp_app: :my_app
      end

  Then add to your supervision tree in `lib/my_app/application.ex`:

      children = [MyApp.Aikido]

  Optionally configure in `config/config.exs` to customize defaults:

      config :my_app, MyApp.Aikido,
        max_tasks: 2000,
        agent_pools: []
  """
  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    storage = Keyword.get(opts, :storage)
    default_slices = Keyword.get(opts, :default_slices)

    instance_options =
      [{:otp_app, otp_app}, {:storage, storage}, {:default_slices, default_slices}]
      |> Enum.filter(fn {key, val} -> key == :otp_app or val != nil end)
      |> Enum.map(fn {key, val} ->
        quote do: unquote(key)(unquote(val))
      end)

    instance_block = {:__block__, [], instance_options}

    quote location: :keep do
      use Aikido.Dsl.Instance.Host

      instance do
        unquote(instance_block)
      end
    end
  end

  @type agent_id :: String.t() | atom()
  @type partition :: term()

  # Default instance name for scripts/Livebook
  @default_instance Aikido.Default

  @doc """
  Returns the default Aikido instance name.

  Used by `Aikido.start/1` for scripts and Livebook quick-start.
  """
  @spec default_instance() :: atom()
  def default_instance, do: @default_instance

  # ---------------------------------------------------------------------------
  # Debug API (default instance delegates)
  # ---------------------------------------------------------------------------

  @doc """
  Controls debug mode for the default Aikido instance (`Aikido.Default`).

  - `debug()` — returns current debug level
  - `debug(:on)` — enable developer-friendly verbosity
  - `debug(:verbose)` — enable maximum detail
  - `debug(:off)` — disable debug overrides
  """
  @spec debug() :: Aikido.Debug.level()
  def debug, do: Aikido.Debug.level(@default_instance)

  @spec debug(Aikido.Debug.level()) :: :ok
  def debug(level) when is_atom(level), do: Aikido.Debug.enable(@default_instance, level)

  @spec debug(Aikido.Debug.level(), keyword()) :: :ok
  def debug(level, opts) when is_atom(level),
    do: Aikido.Debug.enable(@default_instance, level, opts)

  @doc """
  Start the default Aikido instance for scripts and Livebook.

  This is an idempotent convenience function - safe to call multiple times
  (returns `{:ok, pid}` even if already started).

  ## Examples

      # In a script or Livebook
      {:ok, _} = Aikido.start()
      {:ok, pid} = Aikido.start_agent(Aikido.default_instance(), MyAgent)

      # With custom options
      {:ok, _} = Aikido.start(max_tasks: 2000)

  ## Options

  Same as `start_link/1`, but `:name` defaults to `Aikido.Default`.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    opts = Keyword.put_new(opts, :name, @default_instance)

    case start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Stop a Aikido instance.

  Defaults to stopping the default instance (`Aikido.Default`).

  ## Examples

      Aikido.stop()
      Aikido.stop(MyApp.Aikido)

  """
  @spec stop(atom()) :: :ok
  def stop(name \\ @default_instance) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  @doc """
  Starts a Aikido instance supervisor.

  ## Options
    - `:name` - Defaults to `Aikido.Default`. Override for multiple runtimes.

  ## Example

      {:ok, pid} = Aikido.start_link(name: MyApp.Aikido)
  """
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, @default_instance)
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def child_spec(opts) do
    opts = Keyword.put_new(opts, :name, @default_instance)
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: Defaults.aikido_shutdown_timeout_ms()
    }
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    runtime_store = runtime_store_name(name)

    if otp_app = opts[:otp_app] do
      Aikido.Debug.maybe_enable_from_config(otp_app, name)
    end

    :ok = Aikido.RuntimeStore.ensure_table(runtime_store)

    base_children = [
      {Task.Supervisor,
       name: task_supervisor_name(name), max_children: Keyword.get(opts, :max_tasks, 1000)},
      {Registry, keys: :unique, name: registry_name(name)},
      {Aikido.RuntimeStore, name: runtime_store},
      {DynamicSupervisor,
       name: agent_supervisor_name(name),
       strategy: :one_for_one,
       max_restarts: 1000,
       max_seconds: 5}
    ]

    pool_children =
      WorkerPool.build_pool_child_specs(name, Keyword.get(opts, :agent_pools, []))

    durable_children =
      case Keyword.get(opts, :durable, Application.get_env(:aikido, :durable, [])) do
        false ->
          []

        durable_opts when is_list(durable_opts) ->
          [
            {Aikido.Durable,
             Keyword.merge(durable_opts, name: durable_supervisor_name(name), aikido: name)}
          ]
      end

    Supervisor.init(base_children ++ durable_children ++ pool_children, strategy: :one_for_one)
  end

  @doc """
  Generate a unique identifier.

  Delegates to `Aikido.Util.generate_id/0`.
  """
  defdelegate generate_id(), to: Aikido.Util

  @doc "Returns the Registry name for a Aikido instance."
  @spec registry_name(atom()) :: atom()
  def registry_name(name), do: Module.concat(name, Registry)

  @doc "Returns the AgentSupervisor name for a Aikido instance."
  @spec agent_supervisor_name(atom()) :: atom()
  def agent_supervisor_name(name), do: Module.concat(name, AgentSupervisor)

  @doc "Returns the DurableServer supervisor name for this instance."
  def durable_supervisor_name(name), do: Module.concat(name, DurableAgents)

  @doc "Returns the TaskSupervisor name for a Aikido instance."
  @spec task_supervisor_name(atom()) :: atom()
  def task_supervisor_name(name), do: Module.concat(name, TaskSupervisor)

  @doc "Returns the RuntimeStore name for a Aikido instance."
  @spec runtime_store_name(atom()) :: atom()
  def runtime_store_name(name), do: Module.concat(name, RuntimeStore)

  @doc "Returns the Scheduler name for a Aikido instance."
  @spec scheduler_name(atom()) :: atom()
  def scheduler_name(name), do: Module.concat(name, Scheduler)

  @doc "Returns the AgentPool name for a specific pool in a Aikido instance."
  @spec agent_pool_name(atom(), atom()) :: atom()
  def agent_pool_name(name, pool_name), do: Module.concat([name, AgentPool, pool_name])

  @doc false
  @spec partition_key(term(), partition() | nil) :: term()
  def partition_key(value, nil), do: value
  def partition_key(value, partition), do: {:partition, partition, value}

  @doc false
  @spec unwrap_partition_key(term()) :: {partition() | nil, term()}
  def unwrap_partition_key({:partition, partition, value}), do: {partition, value}
  def unwrap_partition_key(value), do: {nil, value}

  # ---------------------------------------------------------------------------
  # Agent Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts an agent under a specific Aikido instance.

  ## Examples

      {:ok, pid} = Aikido.start_agent(MyApp.Aikido, MyAgent)
      {:ok, pid} = Aikido.start_agent(MyApp.Aikido, MyAgent, id: "custom-id")
  """
  @spec start_agent(atom(), module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(aikido_instance, agent_module, opts \\ [])
      when is_atom(aikido_instance) and is_atom(agent_module) do
    {restart, opts} = Keyword.pop(opts, :restart, :permanent)

    if Process.whereis(durable_supervisor_name(aikido_instance)) do
      id = Keyword.get_lazy(opts, :id, &Aikido.generate_id/0)

      Aikido.Durable.ensure_started(durable_supervisor_name(aikido_instance), id,
        agent: agent_module,
        initial_state: Keyword.get(opts, :initial_state, %{}),
        partition: opts[:partition],
        agent_opts: opts,
        permanent: restart != :temporary
      )
    else
      child_spec =
        {Aikido.AgentServer,
         Keyword.merge(opts, agent_module: agent_module, aikido: aikido_instance)}
        |> Supervisor.child_spec(restart: restart)

      DynamicSupervisor.start_child(agent_supervisor_name(aikido_instance), child_spec)
    end
  end

  @doc """
  Stops an agent by pid or id.

  Native agent resources with `persistence :temporary` delete their durable
  snapshot. Permanent resources and plain agent modules retain it.

  ## Examples

      :ok = Aikido.stop_agent(MyApp.Aikido, pid)
      :ok = Aikido.stop_agent(MyApp.Aikido, "agent-id")
  """
  @spec stop_agent(atom(), pid() | String.t()) :: :ok | {:error, term()}
  def stop_agent(aikido_instance, pid) when is_atom(aikido_instance) and is_pid(pid) do
    with {:ok, {pool, key, partition, keep_snapshot?}} <-
           Aikido.AgentServer.state(pid, fn runtime ->
             {:ok,
              {runtime.lifecycle.pool, runtime.lifecycle.pool_key, runtime.partition,
               Aikido.Durable.keep_snapshot?(runtime.agent_module)}}
           end) do
      cond do
        is_nil(pool) ->
          DynamicSupervisor.terminate_child(agent_supervisor_name(aikido_instance), pid)

        keep_snapshot? ->
          DurableServer.Supervisor.terminate_child_permanent(pool, pid)

        true ->
          Aikido.Durable.delete(pool, key, partition: partition)
      end
    end
  end

  def stop_agent(aikido_instance, id) when is_atom(aikido_instance) and is_binary(id) do
    case whereis(aikido_instance, id) do
      nil -> {:error, :not_found}
      pid -> stop_agent(aikido_instance, pid)
    end
  end

  @spec stop_agent(atom(), pid() | String.t(), keyword()) :: :ok | {:error, term()}
  def stop_agent(aikido_instance, pid, _opts)
      when is_atom(aikido_instance) and is_pid(pid) do
    stop_agent(aikido_instance, pid)
  end

  def stop_agent(aikido_instance, id, opts)
      when is_atom(aikido_instance) and is_binary(id) and is_list(opts) do
    case whereis(aikido_instance, id, opts) do
      nil -> {:error, :not_found}
      pid -> stop_agent(aikido_instance, pid)
    end
  end

  @doc """
  Looks up an agent by ID in a Aikido instance's registry.

  Returns the pid if found, nil otherwise.

  ## Examples

      pid = Aikido.whereis(MyApp.Aikido, "agent-123")
  """
  @spec whereis(atom(), String.t()) :: pid() | nil
  def whereis(aikido_instance, id) when is_atom(aikido_instance) and is_binary(id) do
    whereis(aikido_instance, id, [])
  end

  @spec whereis(atom(), String.t(), keyword()) :: pid() | nil
  def whereis(aikido_instance, id, opts)
      when is_atom(aikido_instance) and is_binary(id) and is_list(opts) do
    registry_key = partition_key(id, Keyword.get(opts, :partition))
    durable = durable_supervisor_name(aikido_instance)

    discovered =
      if Process.whereis(durable), do: Aikido.Durable.lookup(durable, id, opts), else: :error

    case discovered do
      {:ok, pid} ->
        pid

      :error ->
        case Registry.lookup(registry_name(aikido_instance), registry_key) do
          [{pid, _}] -> if node(pid) != node() or Process.alive?(pid), do: pid
          [] -> nil
        end
    end
  end

  @doc """
  Fetches the persisted logical parent binding for a child agent.

  This is the stable runtime relationship lookup API for orchestration layers
  that need to inspect the live parent/child graph without depending on raw
  `RuntimeStore` hive layout.

  Returns `{:ok, binding}` when present, or `:error` when no binding exists.

  ## Examples

      {:ok, binding} = Aikido.parent_binding(MyApp.Aikido, "child-123")
      assert binding.parent_id == "parent-456"
  """
  @spec parent_binding(atom(), String.t()) :: {:ok, map()} | :error
  def parent_binding(aikido_instance, child_id)
      when is_atom(aikido_instance) and is_binary(child_id) do
    parent_binding(aikido_instance, child_id, [])
  end

  @spec parent_binding(atom(), String.t(), keyword()) :: {:ok, map()} | :error
  def parent_binding(aikido_instance, child_id, opts)
      when is_atom(aikido_instance) and is_binary(child_id) and is_list(opts) do
    case RuntimeStore.fetch(
           aikido_instance,
           :relationships,
           partition_key(child_id, Keyword.get(opts, :partition))
         ) do
      {:ok, binding} -> normalize_parent_binding(binding)
      :error -> :error
    end
  end

  @doc """
  Lists all agents running in a Aikido instance.

  Returns a list of `{id, pid}` tuples.

  ## Examples

      agents = Aikido.list_agents(MyApp.Aikido)
      # => [{"agent-1", #PID<0.123.0>}, {"agent-2", #PID<0.124.0>}]
  """
  @spec list_agents(atom()) :: [{String.t(), pid()}]
  def list_agents(aikido_instance) when is_atom(aikido_instance) do
    list_agents(aikido_instance, [])
  end

  @spec list_agents(atom(), keyword()) :: [{String.t(), pid()}]
  def list_agents(aikido_instance, opts) when is_atom(aikido_instance) and is_list(opts) do
    local =
      registry_name(aikido_instance)
      |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> filter_agent_registry_entries(Keyword.get(opts, :partition))

    durable = durable_supervisor_name(aikido_instance)
    global = if Process.whereis(durable), do: Aikido.Durable.members(durable, opts), else: []
    Enum.uniq_by(global ++ local, &elem(&1, 0))
  end

  @doc """
  Returns the count of running agents in a Aikido instance.

  ## Examples

      count = Aikido.agent_count(MyApp.Aikido)
      # => 5
  """
  @spec agent_count(atom()) :: non_neg_integer()
  def agent_count(aikido_instance) when is_atom(aikido_instance) do
    agent_count(aikido_instance, [])
  end

  @spec agent_count(atom(), keyword()) :: non_neg_integer()
  def agent_count(aikido_instance, opts) when is_atom(aikido_instance) and is_list(opts) do
    aikido_instance
    |> list_agents(opts)
    |> length()
  end

  # ---------------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------------

  @doc "Hibernate an agent using the given Aikido instance."
  @spec hibernate(atom(), Aikido.Agent.t()) :: :ok | {:error, term()}
  def hibernate(aikido_instance, agent) when is_atom(aikido_instance) do
    hibernate(aikido_instance, agent, [])
  end

  @spec hibernate(atom(), Aikido.Agent.t(), keyword()) :: :ok | {:error, term()}
  def hibernate(aikido_instance, agent, opts) when is_atom(aikido_instance) and is_list(opts) do
    partition = Keyword.get(opts, :partition)
    agent_module = agent_module_for(agent)

    Aikido.Persist.hibernate(
      aikido_instance,
      agent_module,
      partition_key(agent.id, partition),
      agent
    )
  end

  @doc "Thaw an agent using the given Aikido instance."
  @spec thaw(atom(), module(), term()) :: {:ok, Aikido.Agent.t()} | {:error, term()}
  def thaw(aikido_instance, agent_module, key) when is_atom(aikido_instance) do
    thaw(aikido_instance, agent_module, key, [])
  end

  @spec thaw(atom(), module(), term(), keyword()) :: {:ok, Aikido.Agent.t()} | {:error, term()}
  def thaw(aikido_instance, agent_module, key, opts)
      when is_atom(aikido_instance) and is_list(opts) do
    partition = Keyword.get(opts, :partition)
    Aikido.Persist.thaw(aikido_instance, agent_module, partition_key(key, partition))
  end

  defp filter_agent_registry_entries(entries, partition) do
    Enum.flat_map(entries, fn {registry_key, pid} ->
      case unwrap_partition_key(registry_key) do
        {^partition, id} when is_binary(id) ->
          [{id, pid}]

        {nil, id} when is_nil(partition) and is_binary(id) ->
          [{id, pid}]

        _other ->
          []
      end
    end)
  end

  defp agent_module_for(%{agent_module: mod}) when is_atom(mod) and not is_nil(mod), do: mod
  defp agent_module_for(%mod{}), do: mod

  defp normalize_parent_binding(%{parent_id: parent_id, tag: _tag} = binding)
       when is_binary(parent_id) do
    {:ok,
     binding
     |> Map.put_new(:parent_partition, nil)
     |> Map.update(:meta, %{}, fn
       meta when is_map(meta) -> meta
       _other -> %{}
     end)}
  end

  defp normalize_parent_binding(_binding), do: :error
end
