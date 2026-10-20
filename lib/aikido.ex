defmodule Aikido do
  use Supervisor

  alias Aikido.Config.Defaults

  @moduledoc """
  自動 (Aikido) - An autonomous agent framework for Elixir, built for workflows and
  multi-agent systems.

  ## Quick Start

  Add the default runtime to your supervision tree:

      children = [Aikido]

  For a separate named runtime, define your own supervisor module:

      defmodule MyApp.Aikido do
        use Aikido, otp_app: :my_app
      end

  Add to your supervision tree:

      children = [MyApp.Aikido]

  Start and manage agents:

      {:ok, pid} = Aikido.start_agent(MyApp.Aikido, MyAgent, id: "agent-1")
      pid = Aikido.whereis(MyApp.Aikido, "agent-1")
      agents = Aikido.list_agents(MyApp.Aikido)
      :ok = Aikido.stop_agent(MyApp.Aikido, "agent-1")

  ## Core Concepts

  Aikido agents hold immutable state. Native Ash actions return the next state
  and directives; AgentServer applies that state and executes the directives.

  - **Agents** — Immutable state containers updated by native Ash actions
  - **Actions** — Pure functions that return the next agent state and directives; never perform side effects
  - **Directives** — Descriptions of side effects, executed by the runtime without mutating state

  Side effects belong only in directives. Actions must not send messages, perform
  network or database I/O, spawn processes, or schedule timers. Return directives
  for that work; their results return as signals processed by actions.

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
  Sets up an optional named Aikido supervisor module.

  The default runtime only needs `Aikido` in your supervision tree. Use this
  macro when your application needs its own runtime module.

  ## Options

    - `:otp_app` - Required. Your application name (e.g., `:my_app`).
    - Native Spark options, such as `:extensions` and `:fragments`, pass through
      to the instance DSL host.

  ## Example

      defmodule MyApp.Aikido do
        use Aikido, otp_app: :my_app
      end

  Then add to your supervision tree in `lib/my_app/application.ex`:

      children = [MyApp.Aikido]

  Optionally configure in `config/config.exs` to customize defaults:

      config :my_app, MyApp.Aikido,
        max_tasks: 2000
  """
  defmacro __using__(opts) do
    {otp_app, host_opts} = Keyword.pop!(opts, :otp_app)

    quote location: :keep do
      use Aikido.Dsl.Instance.Host, unquote(host_opts)

      instance do
        otp_app unquote(otp_app)
      end
    end
  end

  @doc """
  Resolve an instance's application configuration and runtime overrides.

  The instance's OTP application comes from its Spark configuration. Explicit
  options override application configuration; the instance module is the default
  supervisor name. Instance modules do not define their own `config` function.
  """
  @spec config(module(), keyword()) :: keyword()
  def config(instance, overrides \\ []) do
    otp_app = Aikido.Dsl.Instance.Info.instance_options(instance) |> Map.fetch!(:otp_app)

    otp_app
    |> Application.get_env(instance, [])
    |> Keyword.merge(overrides)
    |> Keyword.put_new(:name, instance)
    |> Keyword.put_new(:otp_app, otp_app)
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

    if otp_app = opts[:otp_app] do
      Aikido.Debug.maybe_enable_from_config(otp_app, name)
    end

    base_children = [
      {Task.Supervisor,
       name: task_supervisor_name(name), max_children: Keyword.get(opts, :max_tasks, 1000)},
      {DynamicSupervisor, name: process_supervisor_name(name), strategy: :one_for_one}
    ]

    durable_opts = Keyword.get(opts, :durable, Application.get_env(:aikido, :durable, []))

    durable_children = [
      {Aikido.Durable,
       Keyword.merge(durable_opts, name: durable_supervisor_name(name), aikido: name)}
    ]

    Supervisor.init(base_children ++ durable_children, strategy: :one_for_one)
  end

  @doc """
  Generate a unique identifier.

  Delegates to `Ash.UUIDv7.generate/0`.
  """
  defdelegate generate_id(), to: Ash.UUIDv7, as: :generate

  @doc "Supervisor for generic non-agent processes spawned by I/O directives."
  def process_supervisor_name(name), do: Module.concat(name, ProcessSupervisor)

  @doc "Returns the DurableServer supervisor name for this instance."
  def durable_supervisor_name(name), do: Module.concat(name, DurableAgents)

  @doc "Returns the TaskSupervisor name for a Aikido instance."
  @spec task_supervisor_name(atom()) :: atom()
  def task_supervisor_name(name), do: Module.concat(name, TaskSupervisor)

  # ---------------------------------------------------------------------------
  # Agent Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts an agent under a specific Aikido instance.

  ## Examples

      {:ok, pid} = Aikido.start_agent(MyApp.Aikido, MyAgent)
      {:ok, pid} = Aikido.start_agent(MyApp.Aikido, MyAgent, id: "custom-id")
  """
  @spec start_agent(atom(), module(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(aikido_instance, agent_module, opts \\ [])
      when is_atom(aikido_instance) and is_atom(agent_module) do
    {restart?, opts} = Keyword.pop(opts, :restart?, true)

    id =
      case Keyword.get(opts, :id) do
        value when value in [nil, ""] -> Ash.UUIDv7.generate()
        value -> value
      end

    Aikido.Durable.start(durable_supervisor_name(aikido_instance), id,
      agent: agent_module,
      initial_state: Keyword.get(opts, :initial_state, %{}),
      partition: opts[:partition],
      agent_opts: opts,
      permanent: restart?
    )
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
              {runtime.durable_server, runtime.durable_key, runtime.partition,
               Aikido.Durable.keep_snapshot?(runtime.agent_module)}}
           end) do
      if keep_snapshot?,
        do: DurableServer.Supervisor.terminate_child_permanent(pool, pid),
        else: Aikido.Durable.delete(pool, key, partition: partition)
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
  Looks up an agent by ID through the instance's DurableServer supervisor.

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
    durable = durable_supervisor_name(aikido_instance)

    if Process.whereis(durable) do
      case Aikido.Durable.lookup(durable, id, opts) do
        {:ok, pid} -> pid
        :error -> nil
      end
    end
  end

  @doc """
  Fetches the persisted logical parent binding for a child agent.

  Reads the current runtime binding for an active child, or its DurableServer
  snapshot when stopped. Reading a stopped binding does not activate the child.

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
    case whereis(aikido_instance, child_id, opts) do
      pid when is_pid(pid) ->
        Aikido.AgentServer.state(pid, fn runtime ->
          case runtime.parent do
            nil ->
              :error

            parent ->
              normalize_parent_binding(%{
                parent_id: parent.id,
                parent_partition: parent.partition,
                tag: parent.tag,
                meta: parent.meta
              })
          end
        end)

      nil ->
        Aikido.Durable.parent_binding(durable_supervisor_name(aikido_instance), child_id, opts)
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
    durable = durable_supervisor_name(aikido_instance)
    if Process.whereis(durable), do: Aikido.Durable.members(durable, opts), else: []
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
