defmodule Aikido.Directives do
  @moduledoc """
  Framework-level directive structs and constructor helpers.

  A *directive* is a pure description of an external effect for the runtime
  (e.g. `Aikido.AgentServer`) to execute. Reducers **never**
  interpret or execute directives; they only emit them.

  ## The Bright Line

  - **Directives mutate no state.** Not domain (`agent.state`), not runtime
    (`%AgentServer.State{}`), nothing. They do I/O — emit signals, spawn
    processes, schedule messages, persist to disk — and return immediately.
  - **Results, if any, come back as signals that re-enter the pipeline.**
    Bookkeeping that logically follows the I/O happens via the cascade
    callbacks `process_signal/2` invokes (`maybe_track_child_started/2`,
    `handle_child_down/3`, `maybe_track_cron_registered/2`, …), not inside
    the directive's `exec/3` body.
  - **The type system enforces it.** `Aikido.Directive.exec/3`
    returns `:ok | {:stop, term()}` — there is no state slot in the return
    shape, so a directive author cannot accidentally write one.
  - **All `agent.state` writes flow through the action's return value.**
    Sole exception is middleware `ctx.agent` staging for I/O purposes.

  ## Core Directives

  Each directive is one struct in its own file under `lib/aikido/directives/`:

  - `Aikido.Directives.Emit` — send a signal directly to a process
  - `Aikido.Directives.Notify` — publish a native Ash notification
  - `Aikido.Directives.Error` — signal an error (wraps `Aikido.Error.t()`)
  - `Aikido.Directives.Spawn` — spawn a generic BEAM child process (fire-and-forget, no tracking)
  - `Aikido.Directives.AsyncTask` — run supervised async work and report success/error as signals
  - `Aikido.Directives.SpawnAgent` — spawn a child Aikido agent with hierarchy tracking
  - `Aikido.Directives.AdoptChild` — attach an orphaned child to current parent
  - `Aikido.Directives.StopChild` — request a tracked child agent to stop gracefully
  - `Aikido.Directives.Schedule` — schedule a delayed message
  - `Aikido.Directives.Stop` — stop the agent process (self)
  - `Aikido.Directives.Cron` — register a cron schedule
  - `Aikido.Directives.CronCancel` — cancel a cron schedule
  - `Aikido.Directives.Reply` — reply to a synchronous call

  Slice-owned directives live next to their slice (e.g.
  `Aikido.AiReact.Directives.LLMCall`).

  ## Usage

      alias Aikido.Directives

      # Deliver locally or to another process
      %Directives.Emit{signal: my_signal}
      %Directives.Emit{signal: my_signal, target: pid}

      # Schedule for later
      %Directives.Schedule{delay_ms: 5000, message: :timeout}

  ## Extensibility

  External packages can define their own directive structs:

      defmodule MyApp.Directives.Notify do
        use Aikido.Directive

        typed_struct do
          field :recipient, :term do
            description "Process that receives the message when this directive executes."
            allow_nil? false
          end

          field :message, :term do
            description "Message delivered to the recipient after the action's state is adopted."
          end
        end

        @impl true
        def exec(directive, _signal, _runtime) do
          send(directive.recipient, directive.message)
          :ok
        end
      end

  The runtime invokes the struct module's behaviour callback. The shared result
  type validates each descriptor's declared fields and directive behaviour.
  """

  alias Aikido.Directives.{
    AdoptChild,
    AsyncTask,
    Cron,
    CronCancel,
    Emit,
    Error,
    Schedule,
    Spawn,
    SpawnAgent,
    Stop,
    StopChild
  }

  @typedoc """
  Any external directive struct (core or extension).

  This is intentionally `struct()` so external packages can define
  their own directive structs without modifying this type.
  """
  @type t :: struct()

  @typedoc "Built-in core directives."
  @type core ::
          Emit.t()
          | Aikido.Directives.Notify.t()
          | Error.t()
          | AsyncTask.t()
          | Spawn.t()
          | SpawnAgent.t()
          | AdoptChild.t()
          | StopChild.t()
          | Schedule.t()
          | Stop.t()
          | Cron.t()
          | CronCancel.t()

  # ============================================================================
  # Helper Constructors
  # ============================================================================

  @doc """
  Creates a signal delivery directive targeting the current agent or a PID.

      Directives.emit(signal)
      Directives.emit(signal, worker_pid)
  """
  @spec emit(term(), pid() | nil) :: Emit.t()
  def emit(signal, target \\ nil), do: %Emit{signal: signal, target: target}

  @doc "Publish a native Ash notification after the action's state is applied."
  @spec notify(Ash.Notifier.Notification.t()) :: Aikido.Directives.Notify.t()
  def notify(notification), do: %Aikido.Directives.Notify{notification: notification}

  @doc """
  Creates an Error directive.

  ## Examples

      Directives.error(Aikido.Error.validation_error("Invalid input"))
      Directives.error(error, :normalize)
  """
  @spec error(term(), atom() | nil) :: Error.t()
  def error(error, context \\ nil) do
    %Error{error: error, context: context}
  end

  @doc """
  Creates a Spawn directive.

  ## Examples

      Directives.spawn({MyWorker, arg: value})
      Directives.spawn(child_spec, :worker_1)
  """
  @spec spawn(term(), term()) :: Spawn.t()
  def spawn(child_spec, tag \\ nil) do
    %Spawn{child_spec: child_spec, tag: tag}
  end

  @doc """
  Creates an AsyncTask directive.

  ## Options

  - `:success_type` - Signal type for successful non-signal results
    (default: `"aikido.async_task.completed"`)
  - `:error_type` - Signal type for errors, exits, throws, and crashes
    (default: `"aikido.async_task.failed"`)
  - `:payload` - Static data merged into generated success/error signal data
  - `:source` - Source for generated signals (defaults to `/agent/:id/async_task`)
  - `:target` - Reply target (defaults to the originating agent process)

  The work may be an MFA tuple (`{module, function, args}`), a zero-arity
  function, or a unary function. Unary functions receive a small runtime context
  map with `:agent_id`, `:input_signal`, `:aikido`, and `:partition`.

  ## Examples

      Directives.async_task({MyApp.Worker, :run, [job_id]},
        success_type: "job.completed",
        error_type: "job.failed",
        payload: %{job_id: job_id}
      )
  """
  @spec async_task(work :: AsyncTask.work(), opts :: keyword()) :: AsyncTask.t()
  def async_task(work, opts \\ []) do
    %AsyncTask{
      work: work,
      success_type: Keyword.get(opts, :success_type, "aikido.async_task.completed"),
      error_type: Keyword.get(opts, :error_type, "aikido.async_task.failed"),
      payload: Keyword.get(opts, :payload, %{}),
      source: Keyword.get(opts, :source),
      target: Keyword.get(opts, :target)
    }
  end

  @doc """
  Creates a SpawnAgent directive for spawning child agents with hierarchy tracking.

  ## Options

  - `:opts` - Additional options for the child AgentServer (map)
    - Supports child startup options like `:id`, `:initial_state`, and `:on_parent_death`
    - Does not support Durable lifecycle options like `:durable_server` or `:durable_key`
  - `:meta` - Metadata to pass to the child via parent reference (map)
  - `:restart?` - Let DurableServer automatically recover a failed child (default: `true`)

  ## Examples

      Directives.spawn_agent(MyWorkerAgent, :worker_1)
      Directives.spawn_agent(MyWorkerAgent, :processor, opts: %{initial_state: %{batch_size: 100}})
      Directives.spawn_agent(MyWorkerAgent, :handler, meta: %{assigned_topic: "events"})
      Directives.spawn_agent(MyWorkerAgent, :durable, restart?: true)
  """
  @spec spawn_agent(term(), term(), keyword()) :: SpawnAgent.t()
  def spawn_agent(agent, tag, options \\ []) do
    opts = Keyword.get(options, :opts, %{})
    meta = Keyword.get(options, :meta, %{})
    restart? = Keyword.get(options, :restart?, true)

    SpawnAgent.new!(agent: agent, tag: tag, opts: opts, meta: meta, restart?: restart?)
  end

  @doc """
  Creates an AdoptChild directive for explicitly attaching a child to the current parent.

  ## Options

  - `:meta` - Metadata to write into the adopted child's new parent reference (map)

  ## Examples

      Directives.adopt_child(child_pid, :worker_1)
      Directives.adopt_child("child-agent-id", :worker_1, meta: %{restored: true})
  """
  @spec adopt_child(pid() | String.t(), term(), keyword()) :: AdoptChild.t()
  def adopt_child(child, tag, opts \\ [])

  def adopt_child(child, tag, opts) when is_pid(child) or is_binary(child) do
    %AdoptChild{
      child: child,
      tag: tag,
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  def adopt_child(child, _tag, _opts) do
    raise Aikido.Error.validation_error(
            "child must be a PID or child id string, got: #{inspect(child)}",
            field: :child
          )
  end

  @doc """
  Creates a StopChild directive to gracefully stop a tracked child agent.

  ## Examples

      Directives.stop_child(:worker_1)
      Directives.stop_child(:processor, :shutdown)
  """
  @spec stop_child(term(), term()) :: StopChild.t()
  def stop_child(tag, reason \\ :normal) do
    %StopChild{tag: tag, reason: reason}
  end

  @doc """
  Creates a Schedule directive.

  ## Examples

      Directives.schedule(5000, :timeout)
      Directives.schedule(1000, {:check, ref})
  """
  @spec schedule(non_neg_integer(), term()) :: Schedule.t()
  def schedule(delay_ms, message) do
    %Schedule{delay_ms: delay_ms, message: message}
  end

  @doc """
  Creates a Stop directive.

  ## Examples

      Directives.stop()
      Directives.stop(:shutdown)
  """
  @spec stop(term()) :: Stop.t()
  def stop(reason \\ :normal) do
    %Stop{reason: reason}
  end

  @doc """
  Creates a Cron directive for recurring scheduled execution.

  ## Options

  - `:job_id` - Logical id for the job (for upsert/cancel)
  - `:timezone` - Timezone identifier

  ## Examples

      Directives.cron("* * * * *", tick_signal)
      Directives.cron("@daily", cleanup_signal, job_id: :daily_cleanup)
      Directives.cron("0 9 * * MON", weekly_signal, job_id: :monday_9am, timezone: "America/New_York")
  """
  @spec cron(term(), term(), keyword()) :: Cron.t()
  def cron(cron_expr, message, opts \\ []) do
    %Cron{
      cron: cron_expr,
      message: message,
      job_id: Keyword.get(opts, :job_id),
      timezone: Keyword.get(opts, :timezone)
    }
  end

  @doc """
  Creates a CronCancel directive to stop a recurring job.

  ## Examples

      Directives.cron_cancel(:heartbeat)
      Directives.cron_cancel(:daily_cleanup)
  """
  @spec cron_cancel(term()) :: CronCancel.t()
  def cron_cancel(job_id) do
    %CronCancel{job_id: job_id}
  end

  # ============================================================================
  # Multi-Agent Communication Helpers
  # ============================================================================

  @doc "Creates a direct asynchronous signal delivery to a PID."
  @spec emit_to_pid(term(), pid()) :: Emit.t()
  def emit_to_pid(signal, pid) when is_pid(pid), do: %Emit{signal: signal, target: pid}
end
