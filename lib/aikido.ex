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

  Start and manage agents through their Ash domain interfaces:

      agent = MyApp.Agents.worker_start!(%{id: "agent-1"})
      MyApp.Agents.worker_inspect!(agent)
      MyApp.Agents.worker_stop!(agent)

  Each runtime starts one shared DurableServer supervision tree for all agents.
  Starting an agent adds a process to that tree, not another runtime supervisor.

  ## Core Concepts

  Aikido agents hold immutable state. Native Ash actions return the next state
  and directives; AgentServer applies that state and executes the directives.

  - **Agents** — Immutable state containers updated by native Ash actions
  - **Actions** — Pure functions that return the next agent state and directives; never perform side effects
  - **Directives** — Descriptions of side effects, executed by the runtime without mutating state

  Side effects belong only in directives. Actions must not send messages, perform
  network or database I/O, spawn processes, or schedule timers. Return directives
  for that work; their results return as signals processed by actions.

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
      use Aikido.Instance.Host, unquote(host_opts)

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
    otp_app = Aikido.Instance.Info.instance_options(instance) |> Map.fetch!(:otp_app)

    otp_app
    |> Application.get_env(instance, [])
    |> Keyword.merge(overrides)
    |> Keyword.put_new(:name, instance)
    |> Keyword.put_new(:otp_app, otp_app)
  end

  # Default instance name for scripts/Livebook
  @default_instance Aikido.Default

  @doc """
  Returns the default Aikido instance name.

  Used by `Aikido.start/1` for scripts and Livebook quick-start.
  """
  @spec default_instance() :: atom()
  def default_instance, do: @default_instance

  @doc """
  Start the default Aikido instance for scripts and Livebook.

  This is an idempotent convenience function - safe to call multiple times
  (returns `{:ok, pid}` even if already started).

  ## Examples

      # In a script or Livebook
      {:ok, _} = Aikido.start()
      agent = MyApp.Agents.worker_start!(%{})

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

    enable_configured_debugging(opts[:otp_app], name)

    opts
    |> runtime_children(name)
    |> Supervisor.init(strategy: :one_for_one)
  end

  defp enable_configured_debugging(nil, _name), do: :ok

  defp enable_configured_debugging(otp_app, name) do
    Aikido.Debug.maybe_enable_from_config(otp_app, name)
  end

  defp runtime_children(opts, name) do
    [
      {Task.Supervisor,
       name: Aikido.task_supervisor_name(name), max_children: Keyword.get(opts, :max_tasks, 1000)},
      {DynamicSupervisor, name: Aikido.process_supervisor_name(name), strategy: :one_for_one},
      {Aikido.Durable, durable_options(opts, name)}
    ]
  end

  defp durable_options(opts, name) do
    opts
    |> Keyword.get(:durable, Application.get_env(:aikido, :durable, []))
    |> Keyword.merge(name: Aikido.durable_supervisor_name(name), aikido: name)
  end

  @doc "Supervisor for generic non-agent processes spawned by I/O directives."
  def process_supervisor_name(name), do: Module.concat(name, ProcessSupervisor)

  @doc "Returns the DurableServer supervisor name for this instance."
  def durable_supervisor_name(name), do: Module.concat(name, DurableAgents)

  @doc "Returns the TaskSupervisor name for a Aikido instance."
  @spec task_supervisor_name(atom()) :: atom()
  def task_supervisor_name(name), do: Module.concat(name, TaskSupervisor)
end
