defmodule Aikido.AgentServer do
  @moduledoc """
  GenServer runtime for Aikido agents.

  AgentServer is the "Act" side of the Aikido framework: while Agents "think"
  (pure native Ash actions), AgentServer "acts" by executing the
  directives they emit. Signal routing happens in AgentServer, keeping
  Agents purely action-oriented.

  ## Architecture

  - One DurableServer process per supervised agent
  - Signals process inline inside the triggering handler; the Erlang
    mailbox is the only queue
  - DurableServer cluster-aware naming by logical ID
  - Logical parent-child hierarchy via state tracking + monitors

  Aikido's parent-child hierarchy is **logical**, not OTP supervisory ancestry.
  Parent and child agents are still OTP peers under a supervisor; the parent
  relationship is represented explicitly with `Aikido.AgentServer.ParentRef`,
  runtime monitors, and lifecycle signals.

  ## Public API

  Start agents through their generated Ash domain actions. AgentServer exposes
  runtime coordination primitives:

  - `call/4` - Synchronous signal processing with selector projection
  - `cast/2` - Asynchronous signal processing
  - `state/3` - Synchronous selector-driven state read (no signal pipeline)

  ## Signal Flow

  ```
  Signal → AgentServer.call/4 (or cast/2)
        → middleware chain (`on_signal/4` wrap)
            → routing → Ash.run_action → {agent, directives}
        → Directives executed inline via Aikido.Directive behaviour
        → call/4 selector runs over post-pipeline state and the result
          is returned to the caller
  ```

  Signal routing is owned by AgentServer, not the Agent. Slices and the
  agent itself declare routes in their Spark DSL to map signal types to action
  references. Unmatched signals are rejected; `aikido.agent.stop` has a built-in fallback.

  ## Options

  - `:aikido` - Aikido instance name for DurableServer scoping (default: `Aikido.Default`)
  - `:agent_module` - Agent module (required). The agent struct is always
    initialized through its native Ash `:initialize` action.
  - `:id` - Instance ID (auto-generated if not provided)
  - `:initial_state` - Initial state map for agent
  - `:default_dispatch` - Default dispatch config for Emit directives (fallback: current agent pid)
  - `:middleware` - List of `module()` or `{module(), opts_map}` middleware appended at runtime
  - `:parent` - Parent reference for hierarchy
  - `:on_parent_death` - Behavior when parent dies:
    - `:stop` - stop the child
    - `:continue` - keep running and become orphaned
    - `:emit_orphan` - become orphaned and process `aikido.agent.orphaned`
  - `:debug` - Enable debug mode with event buffer (default: `false`)

  ## Starting agents

  Add `Aikido` to your application's supervision tree once. All agents in that
  runtime share DurableServer's dynamic supervisor; starting an agent does not
  create another supervisor tree. A separate named runtime creates a separate
  shared tree only when explicitly configured.

  Use the generated domain interface:

      {:ok, agent} = MyApp.Agents.worker_start(%{id: "my-id", counter: 42})
      pid = agent.pid

  The domain action calls the internal activation path through DurableServer.
  Agent processes are supervised independently of the process that invokes the
  domain action.

  ## Completion Detection

  Agents signal completion via **state**, not process death:

      # In an action, return the terminal status as part of slice state:
      slice = %{slice | status: :completed, last_answer: answer}
      Aikido.Types.ActionResult.new(state: slice, directives: [])

      # Subscribe before sending the command, then await its terminal state:
      selector = fn runtime ->
        path = Spark.Dsl.Extension.get_opt(runtime.agent_module, [:agent], :path)
        slice = Map.fetch!(runtime.agent.state, path)

        case slice.status do
          :completed -> {:ok, slice.last_answer}
          :failed -> {:error, slice.error}
          _ -> :skip
        end
      end

      {:ok, answer} =
        Aikido.AgentServer.call_until(server, signal, "**", selector, timeout: 30_000)

  `call_until/5` registers a one-shot subscription before dispatching `signal`.
  The selector runs after matching signals are processed; `:skip` keeps the
  subscription waiting. There are no repeated state queries. For concurrent
  requests, also match the request identifier in the selector.

  This follows Elm/Redux semantics where completion is a state concern.
  The process stays alive until explicitly stopped or supervised.

  **Do NOT** use `{:stop, ...}` from a directive for normal completion—this
  causes race conditions with async work and skips lifecycle hooks.
  See `Aikido.Directive` for details.

  ## Debugging

  AgentServer can record recent events in an in-memory ring buffer (max 50)
  to help diagnose what happened inside a running agent.

  Enable on a running agent:

      :ok = AgentServer.set_debug(pid, true)

  Retrieve recent events (newest-first):

      {:ok, events} = AgentServer.recent_events(pid, limit: 10)

  Each event has the shape `%{at: monotonic_ms, type: atom(), data: map()}`.
  Event types include `:signal_received` and `:directive_started`.

  Returns `{:error, :debug_not_enabled}` if debug mode is off.

  > **Note:** This is a development aid, not an audit log. Events are not
  > persisted and the buffer has fixed capacity.

  ## Orphans and Adoption

  If a child is configured with `on_parent_death: :continue` or `:emit_orphan`,
  the runtime clears the current parent reference immediately when the logical
  parent dies:

  - `state.parent` becomes `nil`
  - the former parent is preserved in `state.orphaned_from`

  Identity (`partition`, `parent`, `orphaned_from`) lives only on
  `%AgentServer.State{}`. Actions reach the current values via
  `input.context.aikido` and emitted
  identity-transition signals (`aikido.agent.identity.*`).

  Reattachment is explicit. A replacement parent can adopt the live child with
  `Aikido.Directives.adopt_child/3`, which refreshes the child's live parent
  reference and monitoring relationship.

  DurableServer snapshots save the current logical parent ID, partition, tag,
  and metadata. Recovery resolves that ID to its current PID. Adoption and
  detachment replace the saved binding, including an explicit nil for orphans.

  ## Waiting Primitives

  Two selector-based primitives let callers wait on agent activity:

  - `call/4` — synchronous request. The caller's selector runs after the
    outermost middleware unwinds and the signal's directives have executed;
    the tagged result is returned to the caller. The same selector contract
    applies as `subscribe/4` (no `:skip` — the caller is blocking).
  - `subscribe/4` + `unsubscribe/2` — ambient subscribe on a signal pattern
    plus a selector. Matching signals fire the selector and dispatch
    `{:ok, _}` / `{:error, _}` to the subscriber; `:skip` keeps listening.

  Both fire after the outermost middleware unwinds, so retry middleware
  that re-invokes `next` produces exactly one return/notification per
  triggering signal.
  """
  @behaviour GenServer
  require Ash.Tracer
  require Logger

  alias Aikido.AgentServer.{
    ChildInfo,
    CronRuntimeSpec,
    Options,
    ParentRef,
    SignalRouter,
    State
  }

  alias Aikido.Directives

  alias Aikido.AgentServer.Signal.{
    ChildExit,
    ChildStarted,
    CronDied,
    CronRestarted,
    IdentityOrphaned,
    LifecycleReady,
    LifecycleStarting,
    LifecycleStopping,
    Orphaned,
    ParentDied,
    PartitionAssigned
  }

  alias Aikido.Config.Defaults
  alias Jido.Signal
  alias Jido.Signal.Router
  alias Aikido.Telemetry.Formatter
  @type server :: pid() | atom() | {:via, module(), term()} | String.t()
  @cron_restart_base_ms 500
  @cron_restart_max_ms 30000
  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------
  @typedoc """
  Selector for `call/4` and `state/3`. Receives the full
  `%AgentServer.State{}`; the slice the user cares about lives at
  `state.agent.state` (or under the agent's declared `path/0`). Must
  return a tagged `{:ok, _}` or `{:error, _}` tuple.

  Selectors run synchronously in the agent process. A raising selector is
  caught and surfaces to the caller as
  `{:error, {:selector_raised, exception, stacktrace}}`.

  No `:skip` return — the caller is blocking, so "skip" has no meaning.
  Use `subscribe/4` for the ambient pattern that supports `:skip`.
  """
  @type call_selector :: (State.t() -> {:ok, term()} | {:error, term()})
  @typedoc """
  Selector for `subscribe/4`. Same calling convention as `call_selector/0`,
  with one extra return value: `:skip` keeps the subscription alive and
  delivers nothing to the subscriber.
  """
  @type subscribe_selector :: (State.t() -> {:ok, term()} | {:error, term()} | :skip)
  @doc """
  Synchronously sends a signal, runs the pipeline, and projects the
  post-pipeline state through `selector`.

  After the outermost middleware unwinds and the signal's directives
  execute, `selector` runs over `%AgentServer.State{}` and its tagged
  return is delivered to the caller. On chain error, the selector is
  **not** invoked — the chain's error is delivered verbatim.

  Middleware that re-invokes `next` does not fire the selector
  multiple times — it fires once per outermost return.

  ## Options

  - `:timeout` — ms to wait (default `Defaults.agent_server_call_timeout_ms/0`)

  ## Returns

  - `{:ok, value}` / `{:error, reason}` — selector return passed through verbatim
  - `{:error, reason}` — chain error from the action / middleware (selector skipped)
  - `{:error, {:selector_raised, exception, stacktrace}}` — selector raised
  - `{:error, :not_found}` / `{:error, :invalid_server}` — server lookup failed
  - Exits with `{:noproc, ...}` / `{:timeout, ...}` if the agent dies or the
    GenServer.call times out

  ## Examples

      {:ok, counter} =
        AgentServer.call(pid, signal, fn s -> {:ok, s.agent.state.counter} end)

      {:ok, :done} =
        AgentServer.call(pid, signal, fn _s -> {:ok, :done} end, timeout: 10_000)
  """
  @spec call(server(), Signal.t(), call_selector(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(server, %Signal{} = signal, selector, opts \\ []) when is_function(selector, 1) do
    timeout = Keyword.get(opts, :timeout, Defaults.agent_server_call_timeout_ms())

    with {:ok, pid} <- resolve_server(server) do
      GenServer.call(
        pid,
        {:signal_with_selector, Aikido.SignalCtx.capture_tracing(signal), selector},
        timeout
      )
    end
  end

  @doc """
  Sends a command and waits for a matching signal to satisfy `selector`.

  Registers a one-shot subscription before dispatch. `:skip` keeps waiting;
  `{:ok, value}` or `{:error, reason}` completes the request. A pipeline error
  returns immediately. A stopped server returns `{:error, {:server_stopped, reason}}`.

  `:timeout` bounds the whole request (default 5 seconds). Timeout does not undo
  an accepted command. Waiting uses an isolated process so late subscription
  replies cannot leak into the caller's mailbox. This is an external-client
  convenience; do not wait for agent workflows inside directive execution.

  The command may be a signal or a zero-arity function returning `{:ok, receipt}`,
  `:ok`, or `{:error, reason}`. Use a function to dispatch through a public Ash
  action with its policies and caller scope. It runs in the isolated waiter after
  subscription registration.
  """
  @type dispatch_command :: Signal.t() | (-> :ok | {:ok, term()} | {:error, term()})
  @spec call_until(server(), dispatch_command(), String.t(), subscribe_selector(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call_until(server, command, pattern, selector, opts \\ [])
      when (is_struct(command, Signal) or is_function(command, 0)) and is_binary(pattern) and
             is_function(selector, 1) do
    timeout = Keyword.get(opts, :timeout, Defaults.agent_server_call_timeout_ms())
    caller = self()
    request = make_ref()

    tracers =
      if is_struct(command, Signal),
        do: Aikido.SignalCtx.tracers(command),
        else:
          Enum.uniq(
            List.wrap(Keyword.get(opts, :tracer)) ++
              List.wrap(Application.get_env(:ash, :tracer)) ++
              List.wrap(Aikido.Telemetry.Config.tracer())
          )

    transfer = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers)

    {waiter, monitor} =
      spawn_monitor(fn ->
        Ash.ProcessHelpers.transfer_context(transfer)
        result = wait_for_command_result(server, command, pattern, selector, timeout)
        send(caller, {request, result})
      end)

    receive do
      {^request, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^waiter, reason} ->
        {:error, {:waiter_stopped, reason}}
    after
      timeout ->
        Process.exit(waiter, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^waiter, _reason} -> :ok
        end

        receive do
          {^request, _result} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp wait_for_command_result(server, command, pattern, selector, timeout) do
    with {:ok, pid} <- resolve_server(server),
         {:ok, ref} <- subscribe(pid, pattern, selector, once: true) do
      monitor = Process.monitor(pid)

      try do
        with :ok <- dispatch_command(pid, command, timeout) do
          receive do
            {:aikido_subscription, ^ref, %{result: result}} -> result
            {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, {:server_stopped, reason}}
          after
            timeout -> {:error, :timeout}
          end
        end
      after
        Process.demonitor(monitor, [:flush])
        unsubscribe(pid, ref)
      end
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:server_stopped, reason}}
  end

  defp dispatch_command(pid, %Signal{} = signal, timeout) do
    case call(pid, signal, fn _ -> {:ok, :accepted} end, timeout: timeout) do
      {:ok, :accepted} -> :ok
      {:error, _} = error -> error
    end
  end

  defp dispatch_command(_pid, command, _timeout) when is_function(command, 0) do
    case command.() do
      :ok -> :ok
      {:ok, _receipt} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Asynchronously sends a signal for processing.

  Returns immediately. The signal is processed in the background.

  ## Returns

  * `:ok` - Signal queued successfully
  * `{:error, :not_found}` - Server not found
  * `{:error, :invalid_server}` - Unsupported server reference

  ## Examples

      :ok = Aikido.AgentServer.cast(pid, signal)
  """
  @spec cast(server(), Signal.t()) :: :ok | {:error, term()}
  def cast(server, %Signal{} = signal) do
    with {:ok, pid} <- resolve_server(server) do
      GenServer.cast(pid, {:signal, Aikido.SignalCtx.capture_tracing(signal)})
    end
  end

  @doc """
  Synchronously read a projection of the agent's `%State{}` without
  running the signal pipeline.

  `selector` runs over the current `%State{}` and its tagged return is
  delivered to the caller. No signal is processed — this is a pure read.

  Use this for liveness checks, bootstrap reads, or test inspection.
  Ash resource reads and typed runtime projections wrap this primitive
  with a selector.

  ## Options

  - `:timeout` — ms to wait (default `Defaults.agent_server_call_timeout_ms/0`)

  ## Returns

  - `{:ok, value}` / `{:error, reason}` — selector return passed through verbatim
  - `{:error, {:selector_raised, exception, stacktrace}}` — selector raised
  - `{:error, :not_found}` / `{:error, :invalid_server}` — server lookup failed

  ## Examples

      # Liveness check
      {:ok, :ok} = AgentServer.state(pid, fn _ -> {:ok, :ok} end)

      # Bootstrap / "what's my agent_id?"
      {:ok, id} = AgentServer.state(pid, fn s -> {:ok, s.id} end)

      # Test inspection
      {:ok, counter} =
        AgentServer.state(pid, fn s -> {:ok, s.agent.state.counter} end)
  """
  @spec state(server(), call_selector(), keyword()) :: {:ok, term()} | {:error, term()}
  def state(server, selector, opts \\ []) when is_function(selector, 1) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, Defaults.agent_server_call_timeout_ms())

    with {:ok, pid} <- resolve_server(server) do
      GenServer.call(pid, {:read_state_with_selector, selector}, timeout)
    end
  end

  @doc """
  Subscribe to signals matching `pattern`, with a selector deciding what
  the subscriber sees.

  The selector runs after the outermost middleware unwinds (same hook
  point as `call/4`). Returning `:skip` keeps the subscription silent and
  alive; `{:ok, _}` / `{:error, _}` dispatches the result to the
  subscriber. With `once: true`, the subscription is removed after the
  first non-`:skip` selector return.

  Patterns are compiled by `Jido.Signal.Router` and have identical
  semantics to `signal_routes/1` declarations: literals (`"work.start"`),
  single-segment wildcards (`"work.*"` matches any single segment after
  `"work."`), and the multi-segment wildcard (`"audit.**"`, or `"**"`
  alone to match every signal regardless of segment count).

  Default dispatch is `{:pid, target: self()}`, which sends
  `{:aikido_subscription, sub_ref, %{signal_type: type, result: result}}`
  to the caller.

  ## Options

  - `:dispatch` — dispatch config (default `{:pid, target: self()}`)
  - `:once` — boolean, if true unsubscribe after first non-`:skip` fire (default `false`)

  ## Returns

  - `{:ok, sub_ref}` — subscription registered; pass `sub_ref` to `unsubscribe/2`
  - `{:error, reason}` — pattern invalid or server lookup failed
  """
  @spec subscribe(server(), String.t(), subscribe_selector(), keyword()) ::
          {:ok, reference()} | {:error, term()}
  def subscribe(server, pattern, selector, opts \\ [])
      when is_binary(pattern) and is_function(selector, 1) do
    dispatch = Keyword.get(opts, :dispatch, {:pid, target: self()})
    once? = Keyword.get(opts, :once, false)

    with {:ok, pid} <- resolve_server(server) do
      GenServer.call(pid, {:subscribe, pattern, selector, dispatch, self(), once?})
    end
  end

  @doc """
  Cancel a subscription created via `subscribe/4`.

  Idempotent — unknown refs are silently ignored.
  """
  @spec unsubscribe(server(), reference()) :: :ok | {:error, term()}
  def unsubscribe(server, sub_ref) when is_reference(sub_ref) do
    with {:ok, pid} <- resolve_server(server) do
      GenServer.cast(pid, {:unsubscribe, sub_ref})
    end
  end

  @doc """
  Block until the AgentServer has emitted `aikido.agent.lifecycle.ready`.

  Useful when callers spawn an agent and need to assert that restoration and
  reconcile + slice start has completed before sending signals or
  reading agent state. If the agent is already past `:idle` (ready
  fired before the call), replies immediately.

  Readiness also emits `[:aikido, :agent_server, :ready]` telemetry with the
  agent ID, module, instance and partition. Observers can register before
  starting or restarting an agent to discover its new process.

  ## Options

  - `:timeout` — ms to wait (default `Defaults.agent_server_await_timeout_ms/0`)

  ## Returns

  - `:ok` - Agent is ready
  - `{:error, :timeout}` - Did not become ready in `timeout` ms
  - `{:error, {:down, reason}}` - Agent process exited while waiting
  - `{:error, :not_found}` - Server reference did not resolve
  """
  @spec await_ready(server(), keyword()) :: :ok | {:error, :timeout | {:down, term()} | term()}
  def await_ready(server, opts \\ []) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, Defaults.agent_server_await_timeout_ms())

    case resolve_server(server) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        GenServer.cast(pid, {:register_ready_waiter, self(), ref})

        receive do
          {:aikido_ready, ^ref} ->
            Process.demonitor(ref, [:flush])
            :ok

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:error, {:down, reason}}
        after
          timeout ->
            GenServer.cast(pid, {:cancel_ready_waiter, ref})
            Process.demonitor(ref, [:flush])
            {:error, :timeout}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Wait for a child with the given tag to be registered under the agent.

  Thin wrapper over `subscribe/4` with `once: true`. Fast-paths via
  `{:get_child_pid, tag}` when the child is already present; otherwise
  subscribes to `aikido.agent.child.started` and resolves on the first
  matching selector hit.

  ## Options

  - `:timeout` - ms to wait before giving up (defaults to
    `Aikido.Config.Defaults.agent_server_await_timeout_ms/0`)

  ## Returns

  - `{:ok, pid}` - Child registered (either already present or newly appeared)
  - `{:error, :timeout}` - Child did not appear in time
  - `{:error, :not_found}` - Parent server not found via resolution
  """
  @spec await_child(server(), term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def await_child(server, child_tag, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Defaults.agent_server_await_timeout_ms())

    with {:ok, pid} <- resolve_server(server) do
      case GenServer.call(pid, {:get_child_pid, child_tag}) do
        {:ok, child_pid} -> {:ok, child_pid}
        :not_found -> subscribe_and_await_child(pid, child_tag, timeout)
      end
    end
  end

  defp subscribe_and_await_child(pid, child_tag, timeout) do
    selector = fn %State{} = state ->
      case Map.get(state.children, child_tag) do
        %ChildInfo{pid: child_pid} when is_pid(child_pid) -> {:ok, child_pid}
        _ -> :skip
      end
    end

    case subscribe(pid, "aikido.agent.child.started", selector, once: true) do
      {:ok, ref} -> recheck_or_wait_for_child(pid, child_tag, ref, timeout)
      error -> error
    end
  end

  # Re-check after subscribing — the natural `child.started` cast can
  # arrive between the initial `:get_child_pid` reply and the `subscribe`
  # call returning, in which case the cascade already populated
  # state.children but our subscriber wasn't registered in time to
  # observe it.
  defp recheck_or_wait_for_child(pid, child_tag, ref, timeout) do
    case GenServer.call(pid, {:get_child_pid, child_tag}) do
      {:ok, child_pid} ->
        unsubscribe(pid, ref)
        {:ok, child_pid}

      :not_found ->
        wait_for_child_subscription(pid, ref, timeout)
    end
  end

  defp wait_for_child_subscription(server, ref, timeout) do
    receive do
      {:aikido_subscription, ^ref, %{result: {:ok, value}}} -> {:ok, value}
      {:aikido_subscription, ^ref, %{result: {:error, reason}}} -> {:error, reason}
    after
      timeout ->
        unsubscribe(server, ref)
        {:error, :timeout}
    end
  end

  @doc """
  Enables or disables debug mode at runtime.

  When debug mode is enabled, the agent records recent events in a ring buffer
  for diagnostic purposes.

  ## Examples

      :ok = AgentServer.set_debug(pid, true)
      # ... run some operations ...
      {:ok, events} = AgentServer.recent_events(pid)
  """
  @spec set_debug(server(), boolean()) :: :ok | {:error, term()}
  def set_debug(server, enabled) when is_boolean(enabled) do
    with {:ok, pid} <- resolve_server(server) do
      GenServer.call(pid, {:set_debug, enabled})
    end
  end

  @doc """
  Retrieves recent debug events from the agent's event buffer.

  Events are returned newest-first. Each event includes:
  - `:at` - Monotonic timestamp in milliseconds
  - `:type` - Event type atom (e.g., `:signal_received`, `:directive_started`)
  - `:data` - Event-specific data map

  Returns `{:error, :debug_not_enabled}` if debug mode is off.

  ## Options

  - `:limit` - Maximum number of events to return (default: all, max 50)

  ## Examples

      {:ok, events} = AgentServer.recent_events(pid, limit: 10)
  """
  @spec recent_events(server(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recent_events(server, opts \\ []) do
    with {:ok, pid} <- resolve_server(server) do
      GenServer.call(pid, {:recent_events, opts})
    end
  end

  @doc """
  Check if the agent server process is alive.
  """
  @spec alive?(server()) :: boolean()
  def alive?(server) when is_pid(server) do
    Process.alive?(server)
  end

  def alive?(server) do
    case resolve_server(server) do
      {:ok, pid} -> Process.alive?(pid)
      {:error, _} -> false
    end
  end

  @doc """
  Low-level primitive: imperatively attach a running agent to a parent ref.

  Used internally by the `%Aikido.Directives.AdoptChild{}` executor to
  push the parent relationship into the child's live `state.parent`.
  Prefer booting the child with `parent: parent_ref` in its AgentServer
  options (`State.from_options/3` consumes it) so `post_init` can emit
  `aikido.agent.child.started` declaratively — this function exists for
  the explicit-adoption-at-runtime path only.
  """
  @spec adopt_parent(server(), ParentRef.t()) ::
          {:ok, %{id: String.t(), agent_module: module(), partition: term() | nil}}
          | {:error, term()}
  def adopt_parent(server, %ParentRef{} = parent_ref) do
    with {:ok, pid} <- resolve_server(server) do
      try do
        GenServer.call(pid, {:adopt_parent, parent_ref})
      catch
        :exit, {:noproc, _} -> {:error, :not_found}
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, reason}
      end
    end
  end

  @doc """
  Imperative counterpart to `Aikido.Directives.adopt_child/3`.

  Adopts a live child into this agent's logical child map. Updates both
  the child's live parent reference and the manager's tracked
  `state.children` map before returning.

  Prefer returning a `%Aikido.Directives.AdoptChild{}` from an action
  when the initiator is already inside an agent — this function is for
  external callers (tests, supervisors, LiveView mounts) that need to
  attach children from outside the signal/directive pipeline.
  """
  @spec adopt_child(server(), pid() | String.t(), term(), map()) ::
          {:ok, pid()} | {:error, term()}
  def adopt_child(server, child, tag, meta \\ %{}) do
    with {:ok, parent_pid} <- resolve_server(server),
         {:ok, runtime} <- state(parent_pid, &{:ok, &1}),
         :ok <- ensure_adopt_tag_available(runtime, tag),
         {:ok, child_pid} <- resolve_adopt_child(child, runtime),
         true <- child_pid != parent_pid || {:error, :cannot_adopt_self} do
      parent_ref =
        ParentRef.new!(%{
          pid: parent_pid,
          id: runtime.id,
          partition: runtime.partition,
          tag: tag,
          meta: meta
        })

      with {:ok, _binding} <- adopt_parent(child_pid, parent_ref) do
        await_child(parent_pid, tag)
      end
    end
  end

  @doc """
  Requests graceful termination of a tracked child agent.

  This is the runtime counterpart to `Directives.stop_child/2`.
  """
  @spec stop_child(server(), term(), term()) :: :ok | {:error, term()}
  def stop_child(server, tag, reason \\ :normal) do
    with {:ok, pid} <- resolve_server(server) do
      try do
        GenServer.call(pid, {:stop_child, tag, reason})
      catch
        :exit, {:noproc, _} -> {:error, :not_found}
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  @doc false
  @spec start_runtime_cron_job(State.t(), term(), CronRuntimeSpec.t()) ::
          {:ok, pid()} | {:error, term()}
  def start_runtime_cron_job(%State{} = state, logical_id, %CronRuntimeSpec{} = runtime_spec) do
    agent_pid = self()
    agent_id = state.id

    Aikido.Scheduler.run_every(
      fn ->
        if Process.alive?(agent_pid) do
          signal = CronRuntimeSpec.build_signal(runtime_spec, agent_id, logical_id)
          _ = Aikido.AgentServer.cast(agent_pid, signal)
        end

        :ok
      end,
      runtime_spec.cron_expression,
      timezone: runtime_spec.timezone
    )
  end

  @doc false
  @spec register_runtime_cron_job(State.t(), term(), CronRuntimeSpec.t()) ::
          {:ok, State.t()} | {:error, term(), State.t()}
  def register_runtime_cron_job(%State{} = state, logical_id, %CronRuntimeSpec{} = runtime_spec) do
    case start_runtime_cron_job(state, logical_id, runtime_spec) do
      {:ok, pid} ->
        {:ok, track_cron_job(state, logical_id, pid, runtime_spec: runtime_spec)}

      {:error, reason} ->
        Logger.error(
          "AgentServer #{state.id} failed to register #{runtime_cron_log_label(runtime_spec)} #{inspect(logical_id)}: #{inspect(reason)}"
        )

        {:error, reason, state}
    end
  end

  defp runtime_cron_log_label(%CronRuntimeSpec{kind: :dynamic}) do
    "runtime cron job"
  end

  defp runtime_cron_log_label(%CronRuntimeSpec{kind: :schedule}) do
    "schedule"
  end

  @doc false
  @spec track_cron_job(State.t(), term(), pid(), keyword()) :: State.t()
  def track_cron_job(%State{} = state, logical_id, pid, opts \\ []) when is_pid(pid) do
    runtime_spec = Keyword.get(opts, :runtime_spec)
    previous_pid = Map.get(state.cron_jobs, logical_id)
    monitor_ref = Keyword.get(opts, :monitor_ref) || Process.monitor(pid)

    state =
      if previous_pid == pid && state.cron_monitors[logical_id] == monitor_ref do
        state
      else
        {_old_pid, cleaned} =
          untrack_cron_job(state, logical_id,
            cancel?: previous_pid != pid,
            input_signal: opts[:input_signal]
          )

        cleaned
      end

    state =
      if is_struct(runtime_spec, CronRuntimeSpec) do
        %{state | cron_runtime_specs: Map.put(state.cron_runtime_specs, logical_id, runtime_spec)}
      else
        state
      end

    %{
      state
      | cron_jobs: Map.put(state.cron_jobs, logical_id, pid),
        cron_monitors: Map.put(state.cron_monitors, logical_id, monitor_ref),
        cron_monitor_refs: Map.put(state.cron_monitor_refs, monitor_ref, logical_id),
        cron_restart_attempts: Map.delete(state.cron_restart_attempts, logical_id)
    }
  end

  @doc false
  @spec untrack_cron_job(State.t(), term(), keyword()) :: {pid() | nil, State.t()}
  def untrack_cron_job(%State{} = state, logical_id, opts \\ []) do
    cancel? = Keyword.get(opts, :cancel?, false)
    drop_runtime_spec? = Keyword.get(opts, :drop_runtime_spec?, false)
    pid = Map.get(state.cron_jobs, logical_id)
    monitor_ref = Map.get(state.cron_monitors, logical_id)
    timer_ref = Map.get(state.cron_restart_timers, logical_id)

    if is_reference(monitor_ref) do
      Process.demonitor(monitor_ref, [:flush])
    end

    if is_reference(timer_ref) do
      :erlang.cancel_timer(timer_ref)
    end

    new_state = %{
      state
      | cron_jobs: Map.delete(state.cron_jobs, logical_id),
        cron_monitors: Map.delete(state.cron_monitors, logical_id),
        cron_monitor_refs:
          if is_reference(monitor_ref) do
            Map.delete(state.cron_monitor_refs, monitor_ref)
          else
            state.cron_monitor_refs
          end,
        cron_restart_attempts: Map.delete(state.cron_restart_attempts, logical_id),
        cron_restart_timers: Map.delete(state.cron_restart_timers, logical_id),
        cron_restart_timer_refs:
          if is_reference(timer_ref) do
            Map.delete(state.cron_restart_timer_refs, timer_ref)
          else
            state.cron_restart_timer_refs
          end,
        cron_runtime_specs:
          if drop_runtime_spec? do
            Map.delete(state.cron_runtime_specs, logical_id)
          else
            state.cron_runtime_specs
          end,
        cron_specs:
          if(drop_runtime_spec?,
            do: Map.delete(state.cron_specs, logical_id),
            else: state.cron_specs
          )
    }

    if cancel? and is_pid(pid) and Process.alive?(pid) do
      Aikido.Directives.CronCancel.exec(
        %Aikido.Directives.CronCancel{job_id: logical_id},
        opts[:input_signal] || Jido.Signal.new!("aikido.agent.cron.cancel", %{job_id: logical_id}),
        state
      )
    end

    {pid, new_state}
  end

  @doc false
  @spec emit_cron_telemetry_event(State.t(), atom(), map()) :: :ok
  def emit_cron_telemetry_event(%State{} = state, event, metadata \\ %{})
      when is_atom(event) and is_map(metadata) do
    emit_telemetry(
      [:aikido, :agent_server, :cron, event],
      %{system_time: System.system_time()},
      Map.merge(
        %{
          agent_id: state.id,
          agent_module: state.agent_module,
          aikido_instance: state.aikido,
          aikido_partition: state.partition
        },
        metadata
      )
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------
  @impl true
  def init(raw_opts) do
    opts =
      if is_map(raw_opts) do
        Map.to_list(raw_opts)
      else
        raw_opts
      end

    {restored_agent, opts} = Keyword.pop(opts, :restored_agent)
    {restored_cron, opts} = Keyword.pop(opts, :restored_cron_specs, %{})

    with {:ok, options} <- Options.new(opts),
         agent_module = options.agent_module,
         chain = build_middleware_chain(agent_module, options),
         agent = restored_agent || build_agent(agent_module, options),
         {:ok, state} <-
           State.from_options(options, agent_module, agent, middleware_chain: chain) do
      state = maybe_monitor_parent(state)

      # Lifecycle observers see restored domain state before schedules start.
      signal_router = SignalRouter.build(state)
      state = %{state | signal_router: signal_router}
      state = emit_through_chain(state, lifecycle_starting_signal(state))
      state = restore_cron_specs(state, restored_cron)
      state = emit_through_chain(state, partition_assigned_signal(state))
      {:ok, state, {:continue, :post_init}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp build_agent(agent_module, %Options{id: id, initial_state: state}) do
    agent_module
    |> Ash.ActionInput.for_action(:initialize, %{id: id, state: state}, authorize?: false)
    |> Ash.run_action!(authorize?: false)
  end

  defp lifecycle_starting_signal(%State{} = state) do
    LifecycleStarting.new!(%{}, source: "/agent/#{state.id}")
  end

  defp lifecycle_ready_signal(%State{} = state) do
    LifecycleReady.new!(%{}, source: "/agent/#{state.id}")
  end

  defp lifecycle_stopping_signal(%State{} = state, reason) do
    LifecycleStopping.new!(%{reason: reason}, source: "/agent/#{state.id}")
  end

  defp partition_assigned_signal(%State{} = state) do
    PartitionAssigned.new!(%{partition: state.partition}, source: "/agent/#{state.id}")
  end

  @impl true
  def handle_continue(:post_init, state) do
    state = register_slice_schedules(state)
    state = register_restored_cron_specs(state)
    notify_parent_of_startup(state)
    state = emit_through_chain(state, lifecycle_ready_signal(state))
    state = %{state | status: :idle}

    emit_telemetry(
      [:aikido, :agent_server, :ready],
      %{system_time: System.system_time()},
      %{
        agent_id: state.id,
        agent_module: state.agent_module,
        aikido_instance: state.aikido,
        aikido_partition: state.partition
      }
    )

    state = notify_ready_waiters(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:signal_with_selector, %Signal{} = signal, selector}, _from, state)
      when is_function(selector, 1) do
    try do
      case process_signal(state, signal) do
        {:ok, new_state, _directives} ->
          {:reply, invoke_selector(selector, new_state), new_state}

        {:error, committed_state, reason} ->
          # A chain error short-circuits selector evaluation;
          # reason is delivered to the caller verbatim.
          {:reply, {:error, reason}, committed_state}

        {:stop, stop_reason, executed_state} ->
          # A directive returned :stop. Run the selector against the
          # post-directive state so the caller still gets a tagged tuple,
          # then stop after replying.
          reply = invoke_selector(selector, executed_state)
          {:stop, stop_reason, reply, %{executed_state | status: :stopping}}
      end
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        Logger.error("Signal call failed for #{state.id}: #{inspect(kind)} #{inspect(reason)}
" <> Exception.format_stacktrace(stacktrace))

        # Return a clean error to the caller; agent stays alive.
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read_state_with_selector, selector}, _from, %State{} = state)
      when is_function(selector, 1) do
    # Pure read — no signal pipeline runs. Selector projects %State{}
    # to whatever the caller asked for. Wrap in try/rescue so a raising
    # selector doesn't crash the agent.
    {:reply, invoke_selector(selector, state), state}
  end

  def handle_call({:set_debug, enabled}, _from, %State{} = state) do
    new_state = %{state | debug: enabled}
    {:reply, :ok, new_state}
  end

  def handle_call({:recent_events, opts}, _from, %State{} = state) do
    if state.debug || Aikido.Debug.enabled?(state.aikido) do
      events = State.get_debug_events(state, opts)
      {:reply, {:ok, events}, state}
    else
      {:reply, {:error, :debug_not_enabled}, state}
    end
  end

  def handle_call({:get_child_pid, child_tag}, _from, %State{} = state) do
    case Map.get(state.children, child_tag) do
      %ChildInfo{pid: pid} when is_pid(pid) -> {:reply, {:ok, pid}, state}
      _ -> {:reply, :not_found, state}
    end
  end

  def handle_call(
        {:subscribe, pattern, selector, dispatch, caller_pid, once?},
        _from,
        %State{} = state
      )
      when is_binary(pattern) and is_function(selector, 1) and is_pid(caller_pid) and
             is_boolean(once?) do
    case Router.Validator.validate_path(pattern) do
      {:ok, _} ->
        sub_ref = make_ref()
        monitor_ref = Process.monitor(caller_pid)

        entry = %{
          pattern_compiled: pattern,
          selector: selector,
          dispatch: dispatch,
          monitor_ref: monitor_ref,
          once: once?
        }

        {:reply, {:ok, sub_ref},
         %{state | signal_subscribers: Map.put(state.signal_subscribers, sub_ref, entry)}}

      {:error, reason} ->
        {:reply, {:error, {:invalid_pattern, reason}}, state}
    end
  end

  def handle_call({:adopt_parent, %ParentRef{} = parent_ref}, _from, %State{} = state) do
    case attach_parent(state, parent_ref) do
      {:ok, next} ->
        {:reply,
         {:ok, %{id: next.id, agent_module: next.agent_module, partition: next.partition}}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_child, tag, reason}, _from, %State{} = state) do
    signal =
      Signal.new!(
        "aikido.agent.stop_child",
        %{tag: tag, reason: reason},
        source: "/agent/#{state.id}"
      )

    :ok =
      Aikido.Directives.StopChild.exec(
        %Aikido.Directives.StopChild{tag: tag, reason: reason},
        signal,
        state
      )

    {:reply, :ok, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast({:adopt_parent, %ParentRef{} = parent_ref}, %State{} = state) do
    case attach_parent(state, parent_ref) do
      {:ok, next} ->
        {:noreply, next}

      {:error, reason} ->
        Logger.warning("Agent #{state.id} could not attach parent: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Initial activation can outlive its parent before DurableServer resolves the
  # saved logical binding. Repair only an untouched binding; an existing parent
  # or completed orphan transition must retain its current lifecycle decision.
  def handle_cast(
        {:ensure_initial_parent, %ParentRef{} = parent_ref},
        %State{parent: nil, orphaned_from: nil} = state
      ) do
    handle_cast({:adopt_parent, parent_ref}, state)
  end

  def handle_cast({:ensure_initial_parent, %ParentRef{}}, %State{} = state),
    do: {:noreply, state}

  def handle_cast({:unsubscribe, sub_ref}, %State{} = state) when is_reference(sub_ref) do
    case Map.pop(state.signal_subscribers, sub_ref) do
      {nil, _} ->
        {:noreply, state}

      {%{monitor_ref: monitor_ref}, remaining} ->
        Process.demonitor(monitor_ref, [:flush])
        {:noreply, %{state | signal_subscribers: remaining}}
    end
  end

  def handle_cast({:register_ready_waiter, pid, ref}, %State{status: status} = state)
      when status in [:idle, :stopping] do
    # Already past lifecycle.ready; reply immediately and skip parking.
    send(pid, {:aikido_ready, ref})
    {:noreply, state}
  end

  def handle_cast({:register_ready_waiter, pid, ref}, %State{} = state) do
    {:noreply, %{state | ready_waiters: Map.put(state.ready_waiters, ref, pid)}}
  end

  def handle_cast({:cancel_ready_waiter, ref}, %State{} = state) do
    {:noreply, %{state | ready_waiters: Map.delete(state.ready_waiters, ref)}}
  end

  def handle_cast({:signal, %Signal{} = signal}, state) do
    case process_signal(state, signal) do
      {:ok, new_state, _directives} -> {:noreply, new_state}
      {:error, committed_state, _reason} -> {:noreply, committed_state}
      {:stop, reason, new_state} -> {:stop, reason, %{new_state | status: :stopping}}
    end
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:scheduled_signal, %Signal{} = signal}, state) do
    case process_signal(state, signal) do
      {:ok, new_state, _directives} -> {:noreply, new_state}
      {:error, committed_state, _reason} -> {:noreply, committed_state}
      {:stop, reason, new_state} -> {:stop, reason, %{new_state | status: :stopping}}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.get(state.cron_monitor_refs, ref) do
      nil ->
        state = drop_dead_subscriber(state, ref)

        if match?(%{parent: %ParentRef{pid: ^pid}}, state) do
          handle_parent_down(state, pid, reason)
        else
          handle_child_down(state, pid, reason)
        end

      logical_id ->
        {:noreply, handle_cron_job_down(state, logical_id, pid, reason)}
    end
  end

  def handle_info({:timeout, ref, {:cron_restart, logical_id}}, state) do
    case Map.get(state.cron_restart_timer_refs, ref) do
      ^logical_id ->
        state = clear_cron_restart_timer(state, logical_id)

        case Map.get(state.cron_runtime_specs, logical_id) do
          %CronRuntimeSpec{} = runtime_spec ->
            case register_runtime_cron_job(state, logical_id, runtime_spec) do
              {:ok, new_state} ->
                emit_cron_telemetry_event(new_state, :restart_succeeded, %{
                  job_id: logical_id,
                  cron_expression: runtime_spec.cron_expression
                })

                # Synthesize a lifecycle signal and run it through the
                # agent's own pipeline so `subscribe/4` subscribers see
                # the post-restart state through subscriptions.
                new_pid = Map.fetch!(new_state.cron_jobs, logical_id)
                signal = cron_restarted_signal(new_state, logical_id, new_pid)
                new_state = dispatch_synthetic_signal(signal, new_state)
                {:noreply, new_state}

              {:error, reason, failed_state} ->
                {:noreply, schedule_cron_restart(failed_state, logical_id, reason)}
            end

          _ ->
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:signal, %Signal{} = signal}, state) do
    case process_signal(state, signal) do
      {:ok, new_state, _directives} -> {:noreply, new_state}
      {:error, committed_state, _reason} -> {:noreply, committed_state}
      {:stop, reason, new_state} -> {:stop, reason, %{new_state | status: :stopping}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # Notify lifecycle observers before shutting down owned runtime processes.
    state =
      if clean_shutdown?(reason) do
        emit_through_chain(state, lifecycle_stopping_signal(state, reason))
      else
        state
      end

    # Clean up all cron jobs owned by this agent
    Enum.each(state.cron_jobs, fn {_job_id, pid} ->
      if is_pid(pid) and Process.alive?(pid) do
        Aikido.Scheduler.cancel(pid)
      end
    end)

    :ok
  end

  defp clean_shutdown?(:normal) do
    true
  end

  defp clean_shutdown?(:shutdown) do
    true
  end

  defp clean_shutdown?({:shutdown, _}) do
    true
  end

  defp clean_shutdown?(_) do
    false
  end

  # ---------------------------------------------------------------------------
  # Internal: Signal Processing
  #
  # `process_signal/2` is shared between every signal entry point —
  # `handle_call({:signal_with_selector, ...})`, `handle_cast({:signal, ...})`,
  # `handle_info({:scheduled_signal, ...})`, and the lifecycle-signal
  # `emit_through_chain/2`. It runs the middleware chain, executes the
  # returned directives inline, and fires `subscribe/4` subscribers — then
  # hands back the committed state and the chain's tagged result.
  #
  # Uncaught raises propagate up; the `handle_call` handler catches them
  # and surfaces a clean `{:error, _}` reply, while cast/info handlers
  # let the GenServer crash so supervision can react. The Erlang mailbox
  # is the only queue; new incoming signals wait there until the current
  # handler returns.
  # ---------------------------------------------------------------------------

  @spec process_signal(State.t(), Signal.t()) ::
          {:ok, State.t(), [struct()]} | {:error, State.t(), term()} | {:stop, term(), State.t()}
  defp process_signal(%State{} = state, %Signal{} = signal) do
    with_signal_span(state, signal, &do_process_signal(state, &1))
  end

  defp with_signal_span(state, signal, fun) do
    tracers = Aikido.SignalCtx.tracers(signal, state.aikido)
    previous = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers)
    incoming = Map.new(tracers, &{&1, Map.get(Aikido.SignalCtx.tracer_context(signal), &1)})
    Ash.ProcessHelpers.transfer_context(incoming)
    signal = if tracers == [], do: signal, else: Aikido.SignalCtx.put(signal, :tracer, tracers)

    try do
      Ash.Tracer.span {:custom, :aikido_signal}, signal.type, tracers do
        Ash.Tracer.set_metadata(
          tracers,
          {:custom, :aikido_signal},
          build_signal_metadata(state, signal)
        )

        fun.(signal)
      end
    after
      Ash.ProcessHelpers.transfer_context(previous)
    end
  end

  defp do_process_signal(%State{} = state, %Signal{} = signal) do
    start_time = System.monotonic_time()
    metadata = build_signal_metadata(state, signal)

    state =
      state
      |> State.record_debug_event(:signal_received, %{type: signal.type, id: signal.id})
      |> maybe_track_child_started(signal)
      |> maybe_track_cron_registered(signal)

    emit_telemetry(
      [:aikido, :agent_server, :signal, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = run_chain(signal, state)

      emit_telemetry(
        [:aikido, :agent_server, :signal, :stop],
        %{duration: System.monotonic_time() - start_time},
        Map.merge(metadata, signal_stop_metadata_for(result))
      )

      case result do
        {:ok, new_state, directives} ->
          case execute_directives(directives, signal, new_state) do
            {:ok, executed_state} ->
              executed_state = fire_subscribers(executed_state, signal)
              {:ok, executed_state, directives}

            {:stop, reason, executed_state} ->
              # Subscribers are intentionally not fired on the stop branch
              # — the agent is going down; observers see the :DOWN monitor.
              {:stop, reason, executed_state}
          end

        {:error, new_state, reason} ->
          # Chain returned an error. `new_state` already has any
          # middleware-staged mutations committed; no directives to run on
          # this branch. Subscribers still observe the resulting state.
          new_state = fire_subscribers(new_state, signal)
          {:error, new_state, reason}
      end
    catch
      kind, reason ->
        emit_telemetry(
          [:aikido, :agent_server, :signal, :exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, %{kind: kind, error: reason})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # Invokes a call, state or subscription selector in a try/rescue so a raising
  # selector doesn't crash the agent. Returns the selector's tagged tuple
  # on success or `{:error, {:selector_raised, exception, stacktrace}}` on
  # rescue.
  @spec invoke_selector(subscribe_selector(), State.t()) ::
          {:ok, term()} | {:error, term()} | :skip
  defp invoke_selector(selector, %State{} = state) when is_function(selector, 1) do
    selector.(state)
  rescue
    exception -> {:error, {:selector_raised, exception, __STACKTRACE__}}
  end

  # Middleware chain → routing → native Ash actions. The outermost middleware wraps the
  # whole pipeline; the innermost `next` runs routing + native Ash actions.
  #
  # The chain returns either branch with a fresh ctx; this function
  # commits ctx.agent to state.agent unconditionally so middleware-staged
  # changes land regardless of whether
  # the action errored downstream. Action-level rollback already happened
  # before accepting the action results.
  #
  defp run_chain(%Signal{} = signal, %State{middleware_chain: chain} = state)
       when is_function(chain, 2) do
    ctx = build_signal_ctx(signal, state)

    case chain.(signal, ctx) do
      {:ok, new_ctx, directives} ->
        new_state = %{state | agent: new_ctx.agent}
        {:ok, new_state, List.wrap(directives)}

      {:error, new_ctx, reason} ->
        new_state = %{state | agent: new_ctx.agent}
        {:error, new_state, reason}
    end
  end

  # Routes a lifecycle / identity signal through the middleware chain.
  # Mirrors the agent-state sync in `run_chain/2` and runs any returned
  # directives inline so emitted signals reach observers.
  #
  # Like the user-signal path, subscribers fire after the outermost
  # middleware unwinds and directives have executed.
  defp emit_through_chain(%State{} = state, %Signal{} = signal) do
    with_signal_span(state, signal, fn signal ->
      case run_chain(signal, state) do
        {:ok, next, directives} ->
          executed =
            case execute_directives(directives, signal, next) do
              {:ok, state} -> state
              {:stop, _reason, state} -> state
            end

          fire_subscribers(executed, signal)

        {:error, next, _reason} ->
          fire_subscribers(next, signal)
      end
    end)
  end

  defp build_signal_ctx(%Signal{} = signal, %State{} = state) do
    signal_ctx = Aikido.SignalCtx.ctx(signal)

    base = %{
      agent: state.agent,
      agent_module: state.agent_module,
      agent_id: state.id,
      agent_pid: self(),
      partition: state.partition,
      parent: state.parent,
      orphaned_from: state.orphaned_from,
      aikido: state.aikido,
      cron_specs: state.cron_specs,
      __signal_router__: state.signal_router
    }

    Map.merge(signal_ctx, base)
  end

  @doc false
  # Inline directive loop. Each directive returns `:ok` (bounded I/O;
  # for async effects, spawn a task and emit a signal when done — see
  # the Aikido.Directive docs). `{:stop, reason}` aborts the batch and
  # propagates as `{:stop, reason, state}` to the GenServer.
  #
  # The directive contract has no state slot in its return value:
  # directives mutate no state. This runtime loop records debug events and
  # retires cron cancellation ownership before I/O; cascade callbacks install
  # runtime results received through subsequent signals.
  @spec execute_directives([struct()], Signal.t(), State.t()) ::
          {:ok, State.t()} | {:stop, term(), State.t()}
  def execute_directives(directives, signal, state)

  def execute_directives([], _signal, state) do
    {:ok, state}
  end

  def execute_directives([directive | rest], signal, state) do
    state =
      State.record_debug_event(state, :directive_started, %{
        type: directive.__struct__ |> Module.split() |> List.last(),
        signal_type: signal.type
      })

    # Retire ownership before asynchronous shutdown can deliver its DOWN.
    # The descriptor still receives the old snapshot to address that incarnation.
    next_state =
      case directive do
        %Aikido.Directives.CronCancel{job_id: job_id} ->
          {_pid, next} = untrack_cron_job(state, job_id, drop_runtime_spec?: true)
          next

        _ ->
          state
      end

    result = exec_directive_with_telemetry(directive, signal, state)

    case result do
      :ok ->
        execute_directives(rest, signal, next_state)

      {:stop, reason} ->
        warn_if_normal_stop(reason, directive, next_state)
        {:stop, reason, next_state}
    end
  end

  defp build_signal_metadata(state, signal) do
    %{
      agent_id: state.id,
      agent_module: state.agent_module,
      signal_type: signal.type,
      signal_id: signal.id,
      aikido_instance: state.aikido,
      aikido_partition: state.partition
    }
  end

  defp signal_stop_metadata_for({:ok, _state, directives}) when is_list(directives) do
    %{
      directive_count: length(directives),
      directive_types: Formatter.summarize_directives(directives)
    }
  end

  defp signal_stop_metadata_for({:error, _state, reason}) do
    %{directive_count: 0, directive_types: %{}, error: reason}
  end

  defp maybe_track_child_started(
         %State{id: state_id} = state,
         %Signal{type: "aikido.agent.child.started", data: data}
       )
       when is_map(data) do
    with %{
           parent_id: ^state_id,
           tag: tag,
           pid: pid,
           child_id: child_id,
           child_module: child_module
         } <- data,
         true <- is_pid(pid),
         true <- is_binary(child_id),
         true <- is_atom(child_module) do
      meta = Map.get(data, :meta, %{})
      child_partition = Map.get(data, :child_partition)

      case Map.get(state.children, tag) do
        %ChildInfo{pid: ^pid} ->
          state

        %ChildInfo{ref: ref} ->
          Process.demonitor(ref, [:flush])
          track_child_started(state, pid, child_module, child_id, child_partition, tag, meta)

        nil ->
          track_child_started(state, pid, child_module, child_id, child_partition, tag, meta)
      end
    else
      _ -> state
    end
  end

  defp maybe_track_child_started(state, _signal) do
    state
  end

  defp track_child_started(state, pid, child_module, child_id, child_partition, tag, meta) do
    ref = Process.monitor(pid)

    child_info =
      ChildInfo.new!(%{
        pid: pid,
        ref: ref,
        module: child_module,
        id: child_id,
        partition: child_partition,
        tag: tag,
        meta: meta
      })

    State.add_child(state, tag, child_info)
  end

  # Registration and recovery use the same runtime ownership installer.
  defp maybe_track_cron_registered(
         %State{} = state,
         %Signal{type: "aikido.agent.cron.registered", data: data} = signal
       )
       when is_map(data) do
    case data do
      %{job_id: _, pid: pid, monitor_ref: monitor_ref, cron_spec: _, runtime_spec: _}
      when is_pid(pid) and is_reference(monitor_ref) ->
        commit_cron_io_result(state, data, signal)

      _ ->
        state
    end
  end

  defp maybe_track_cron_registered(state, _signal), do: state

  # ---------------------------------------------------------------------------
  # Internal: subscriber dispatch
  #
  # Subscribers fire after the outermost middleware unwinds and directives
  # have executed (the "post-signal" hook point). They always run their
  # selector against state, independent of the chain
  # outcome. The synchronous `call/4` path delivers its result directly
  # from `handle_call({:signal_with_selector, ...})` — there is no ack
  # table to fire alongside subscribers.
  # ---------------------------------------------------------------------------

  defp fire_subscribers(%State{signal_subscribers: subs} = state, _signal)
       when map_size(subs) == 0 do
    state
  end

  defp fire_subscribers(%State{} = state, %Signal{type: type} = signal) do
    Enum.reduce(state.signal_subscribers, state, fn {sub_ref, entry}, acc_state ->
      if Router.matches?(type, entry.pattern_compiled) do
        fire_matching_subscriber(acc_state, sub_ref, entry, signal)
      else
        acc_state
      end
    end)
  end

  defp fire_matching_subscriber(acc_state, sub_ref, entry, signal) do
    case invoke_selector(entry.selector, acc_state) do
      :skip ->
        acc_state

      {:ok, _value} = fire ->
        dispatch_and_maybe_remove(acc_state, sub_ref, entry, signal, fire)

      {:error, _reason} = fire ->
        dispatch_and_maybe_remove(acc_state, sub_ref, entry, signal, fire)
    end
  end

  defp dispatch_and_maybe_remove(acc_state, sub_ref, entry, signal, fire) do
    dispatch_subscriber(entry.dispatch, sub_ref, signal, fire, acc_state)

    if entry.once do
      remove_subscriber(acc_state, sub_ref)
    else
      acc_state
    end
  end

  defp dispatch_subscriber({:pid, target: target}, sub_ref, %Signal{type: type}, result, _state)
       when is_pid(target) do
    send(target, {:aikido_subscription, sub_ref, %{signal_type: type, result: result}})
    :ok
  end

  defp dispatch_subscriber(dispatch, sub_ref, %Signal{type: type} = signal, result, state) do
    payload = %{signal_type: type, result: result, sub_ref: sub_ref, source_signal: signal}

    case Jido.Signal.new(%{
           type: "aikido.subscription.fire",
           source: signal.source,
           data: payload
         }) do
      {:ok, fire_signal} ->
        Aikido.Directives.Emit.exec(
          %Aikido.Directives.Emit{signal: fire_signal, dispatch: dispatch},
          signal,
          state
        )

      {:error, _} ->
        :ok
    end
  end

  defp remove_subscriber(%State{signal_subscribers: subs} = state, sub_ref) do
    case Map.pop(subs, sub_ref) do
      {nil, _} ->
        state

      {%{monitor_ref: monitor_ref}, remaining} ->
        Process.demonitor(monitor_ref, [:flush])
        %{state | signal_subscribers: remaining}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: Signal Routing
  # ---------------------------------------------------------------------------

  defp route_to_actions(router, signal) do
    case Router.route(router, signal) do
      {:ok, targets} when targets != [] ->
        actions = Enum.map(targets, &target_to_action(&1, signal))
        {:ok, actions}

      {:error, %{details: %{reason: :no_handlers_found}}} ->
        default_system_action(signal)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_system_action(%Signal{type: "aikido.agent.stop", data: data}) do
    params =
      if is_map(data) do
        data
      else
        %{}
      end

    {:ok, [{{Aikido.AgentServer.RuntimeActions, :stop_self}, params}]}
  end

  defp default_system_action(_signal) do
    {:error, :no_matching_route}
  end

  defp target_to_action({resource, action}, %Signal{data: data})
       when is_atom(resource) and is_atom(action) do
    {{resource, action}, data}
  end

  # ---------------------------------------------------------------------------
  # Internal: Middleware Chain Composition
  # ---------------------------------------------------------------------------

  # Builds the on_signal/4 middleware chain for the agent at init time.
  # Order: agent's compile-time `middleware:` ++ runtime `Options.middleware:`.
  #
  # Each entry is normalized to `{Mod, opts_map}` and wrapped around the core
  # next function in declaration order: the first entry becomes the outermost
  # wrap, the last entry the innermost. Duplicate-module detection is left
  # to user discretion — the chain runs whatever is declared, in order.
  defp build_middleware_chain(agent_module, %Options{middleware: runtime_mw}) do
    compile_mw = Aikido.Dsl.Agent.Info.middleware(agent_module)
    all_entries = compile_mw ++ runtime_mw
    compose_chain(all_entries, &core_next/2)
  end

  defp normalize_entry({mod, opts}) when is_atom(mod) and is_map(opts) do
    {mod, opts}
  end

  defp normalize_entry(mod) when is_atom(mod) do
    {mod, %{}}
  end

  defp compose_chain(entries, core_next) do
    Enum.reduce(Enum.reverse(entries), core_next, fn entry, acc_next ->
      {mod, opts} = normalize_entry(entry)
      Code.ensure_loaded(mod)

      if function_exported?(mod, :on_signal, 4) do
        fn sig, ctx -> mod.on_signal(sig, ctx, opts, acc_next) end
      else
        # Module declared `@behaviour Aikido.Middleware` but did not
        # implement `on_signal/4`. The callback is optional — pass the
        # signal through unchanged.
        acc_next
      end
    end)
  end

  # Route directly to native Ash actions. The original context is retained on
  # any failure so partial slice updates and directives cannot escape the turn.
  defp core_next(%Signal{} = signal, ctx) do
    case route_to_actions(ctx.__signal_router__, signal) do
      {:ok, targets} ->
        apply_actions(signal, ctx, targets)

      {:error, reason} ->
        error =
          Aikido.Error.routing_error("No route for signal #{inspect(signal.type)}", %{
            signal_type: signal.type,
            reason: reason
          })

        log_routing_error(ctx, error)
        {:error, ctx, error}
    end
  end

  @doc false
  def apply_actions(%Signal{} = signal, ctx, targets) do
    Enum.reduce_while(targets, {:ok, ctx, []}, fn {reference, params}, {:ok, current, effects} ->
      paths =
        current.agent_module
        |> Aikido.Dsl.Agent.Info.slice_paths_for_action()
        |> Map.get(reference, [Spark.Dsl.Extension.get_opt(current.agent_module, [:agent], :path)])

      Enum.reduce_while(paths, {:ok, current, effects}, fn path, {:ok, current, effects} ->
        case run_action(reference, params || %{}, signal, current, path) do
          {:ok, result} ->
            state =
              case result.state do
                %Aikido.Agent.SliceUpdate{slices: slices} ->
                  Map.merge(current.agent.state, slices)

                slice ->
                  Map.put(current.agent.state, path, slice)
              end

            current = Map.put(current, :agent, %{current.agent | state: state})
            {:cont, {:ok, current, effects ++ result.directives}}

          {:error, reason} ->
            {:halt, {:error, ctx, reason}}
        end
      end)
      |> case do
        {:ok, _, _} = result -> {:cont, result}
        {:error, _, _} = error -> {:halt, error}
      end
    end)
  rescue
    error -> {:error, ctx, Ash.Error.to_error_class(error)}
  end

  defp run_action(reference, params, signal, ctx, path) do
    {resource, name} = reference
    definition = Ash.Resource.Info.action(resource, name)
    state = Map.get(ctx.agent.state, path, %{})

    arguments =
      if Enum.any?(definition.arguments, &(&1.name == :data)),
        do: %{data: params, state: state},
        else: Map.put(params, :state, state)

    runtime =
      Map.merge(ctx, %{
        signal: %{signal | data: params},
        slice_path: path,
        slice_config: Map.get(Aikido.Dsl.Agent.Info.mount_config_map(ctx.agent_module), path, %{})
      })

    options =
      Ash.Scope.to_opts(ctx, context: Map.put(Map.get(ctx, :context) || %{}, :aikido, runtime))

    resource
    |> Ash.ActionInput.for_action(
      name,
      arguments,
      Keyword.put(options, :skip_unknown_inputs, [:*])
    )
    |> Ash.run_action(options)
    |> case do
      {:ok, %Aikido.Types.ActionResult{} = result} ->
        Aikido.Types.ActionResult.new(Map.from_struct(result))

      {:ok, result} ->
        Aikido.Types.ActionResult.new(result)

      error ->
        error
    end
  end

  # Routing failures short-circuit the chain before directives run.
  # Log them here so operators can identify signals without a valid route.
  defp log_routing_error(ctx, %{message: message}) do
    Logger.debug("Agent #{Map.get(ctx, :agent_id, "unknown")} [routing]: #{message}")
  end

  # ---------------------------------------------------------------------------
  # Internal: Slice Schedules
  # ---------------------------------------------------------------------------
  @doc false
  defp register_slice_schedules(%State{skip_schedules: true} = state) do
    Logger.debug("AgentServer #{state.id} skipping slice schedules")
    state
  end

  defp register_slice_schedules(%State{} = state) do
    agent_module = state.agent_module
    schedules = Aikido.Dsl.Agent.Info.schedules(agent_module)

    Enum.reduce(schedules, state, fn schedule_spec, acc_state ->
      register_schedule(acc_state, schedule_spec)
    end)
  end

  defp restore_cron_specs(state, specs) do
    {valid, invalid} = Aikido.Scheduler.classify_cron_specs(specs)

    Enum.each(invalid, fn {job_id, spec, reason} ->
      Logger.error(
        "AgentServer #{state.id} dropped malformed persisted cron spec #{inspect(job_id)}: #{inspect(spec)} (#{inspect(reason)})"
      )
    end)

    %{state | cron_specs: Map.merge(state.cron_specs, valid)}
  end

  defp register_restored_cron_specs(%State{cron_specs: cron_specs} = state)
       when map_size(cron_specs) == 0 do
    state
  end

  defp register_restored_cron_specs(%State{} = state) do
    Enum.reduce(state.cron_specs, state, fn {job_id, spec}, acc_state ->
      register_restored_cron_spec(acc_state, job_id, spec)
    end)
  end

  defp register_restored_cron_spec(
         %State{} = state,
         job_id,
         %{cron_expression: cron_expr, message: message, timezone: timezone}
       ) do
    if Map.has_key?(state.cron_jobs, job_id) do
      Logger.warning(
        "AgentServer #{state.id} skipping restored cron job #{inspect(job_id)} because declarative/slice schedule already exists"
      )

      %{state | cron_specs: Map.delete(state.cron_specs, job_id)}
    else
      register_restored_cron_runtime(state, job_id, cron_expr, message, timezone)
    end
  end

  defp register_restored_cron_spec(%State{} = state, job_id, invalid_spec) do
    Logger.error(
      "AgentServer #{state.id} skipped invalid persisted cron spec #{inspect(job_id)}: #{inspect(invalid_spec)}"
    )

    state
  end

  # GenServer-context helper that restores a persisted cron spec by
  # spawning the scheduler job and installing the runtime maps directly
  # (no synthetic-signal cascade). Used only by the post-init restore
  # path. Mirrors the directive's `register_io/5` flow without the
  # cascade dispatch — directives go through `maybe_track_cron_registered/2`,
  # but a still-initializing GenServer can't rely on signal mailbox
  # turns yet. On failure we drop the persisted spec so a broken entry
  # doesn't block boot.
  defp register_restored_cron_runtime(state, job_id, cron_expr, message, timezone) do
    case Directives.Cron.register_io(state, cron_expr, message, job_id, timezone) do
      {:ok, io_result} ->
        commit_cron_io_result(state, io_result)

      {:error, reason} ->
        Logger.error(
          "AgentServer #{state.id} failed to register cron job #{inspect(job_id)}: #{inspect(reason)}"
        )

        {_pid, runtime_state} =
          untrack_cron_job(state, job_id, cancel?: true, drop_runtime_spec?: true)

        %{runtime_state | cron_specs: Map.delete(runtime_state.cron_specs, job_id)}
    end
  end

  defp commit_cron_io_result(state, io_result, input_signal \\ nil)

  defp commit_cron_io_result(%State{} = state, io_result, input_signal) do
    %{
      job_id: job_id,
      pid: pid,
      monitor_ref: monitor_ref,
      cron_spec: cron_spec,
      runtime_spec: runtime_spec
    } = io_result

    committed =
      track_cron_job(state, job_id, pid,
        runtime_spec: runtime_spec,
        monitor_ref: monitor_ref,
        input_signal: input_signal
      )

    %{committed | cron_specs: Map.put(committed.cron_specs, job_id, cron_spec)}
  end

  defp register_schedule(%State{} = state, schedule_spec) do
    %{
      cron_expression: cron_expr,
      job_id: job_id,
      signal_type: signal_type,
      timezone: timezone
    } = schedule_spec

    runtime_spec =
      CronRuntimeSpec.schedule(
        cron_expr,
        signal_type,
        timezone,
        Map.get(schedule_spec, :data, %{})
      )

    case register_runtime_cron_job(state, job_id, runtime_spec) do
      {:ok, new_state} ->
        Logger.debug(
          "AgentServer #{state.id} registered schedule #{inspect(job_id)}: #{cron_expr}"
        )

        new_state

      {:error, _reason, failed_state} ->
        failed_state
    end
  end

  defp handle_cron_job_down(state, logical_id, pid, reason) do
    {tracked_pid, state} = untrack_cron_job(state, logical_id, cancel?: false)

    if tracked_pid == pid do
      # Emit before scheduling restart so subscribers see the death
      # announcement on a state where `cron_jobs[logical_id]` is already
      # removed. A `aikido.agent.cron.restarted` follows when the restart
      # timer succeeds (only for abnormal exits).
      state = dispatch_synthetic_signal(cron_died_signal(state, logical_id, pid, reason), state)

      if clean_shutdown?(reason) do
        state
      else
        schedule_cron_restart(state, logical_id, reason)
      end
    else
      state
    end
  end

  defp cron_died_signal(%State{} = state, logical_id, pid, reason) do
    CronDied.new!(%{job_id: logical_id, pid: pid, reason: reason},
      source: "/agent/#{state.id}/cron"
    )
  end

  defp cron_restarted_signal(%State{} = state, logical_id, pid) do
    CronRestarted.new!(%{job_id: logical_id, pid: pid},
      source: "/agent/#{state.id}/cron"
    )
  end

  defp schedule_cron_restart(state, logical_id, reason) do
    if Map.has_key?(state.cron_runtime_specs, logical_id) do
      attempt = Map.get(state.cron_restart_attempts, logical_id, 0)

      delay =
        min((@cron_restart_base_ms * :math.pow(2, attempt)) |> trunc(), @cron_restart_max_ms)

      timer_ref = :erlang.start_timer(delay, self(), {:cron_restart, logical_id})

      Logger.warning(
        "AgentServer #{state.id} scheduling cron restart for #{inspect(logical_id)} in #{delay}ms after #{inspect(reason)}"
      )

      emit_cron_telemetry_event(state, :restart_scheduled, %{
        job_id: logical_id,
        reason: reason,
        delay_ms: delay
      })

      %{
        state
        | cron_restart_attempts: Map.put(state.cron_restart_attempts, logical_id, attempt + 1),
          cron_restart_timers: Map.put(state.cron_restart_timers, logical_id, timer_ref),
          cron_restart_timer_refs: Map.put(state.cron_restart_timer_refs, timer_ref, logical_id)
      }
    else
      state
    end
  end

  defp clear_cron_restart_timer(state, logical_id) do
    case Map.pop(state.cron_restart_timers, logical_id) do
      {timer_ref, timers} when is_reference(timer_ref) ->
        %{
          state
          | cron_restart_timers: timers,
            cron_restart_timer_refs: Map.delete(state.cron_restart_timer_refs, timer_ref)
        }

      {_other, timers} ->
        %{state | cron_restart_timers: timers}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: Lifecycle waiters
  # ---------------------------------------------------------------------------

  defp notify_ready_waiters(%State{ready_waiters: waiters} = state) when map_size(waiters) == 0 do
    state
  end

  defp notify_ready_waiters(%State{ready_waiters: waiters} = state) do
    Enum.each(waiters, fn {ref, pid} -> send(pid, {:aikido_ready, ref}) end)
    %{state | ready_waiters: %{}}
  end

  defp drop_dead_subscriber(%State{signal_subscribers: subs} = state, monitor_ref) do
    case Enum.find(subs, fn {_ref, %{monitor_ref: ref}} -> ref == monitor_ref end) do
      {sub_ref, _entry} -> %{state | signal_subscribers: Map.delete(subs, sub_ref)}
      nil -> state
    end
  end

  # ---------------------------------------------------------------------------
  # Server Resolution
  # ---------------------------------------------------------------------------
  @doc """
  Resolves a server reference to a pid.

  Accepts the same reference types as `cast/2` and `call/4` — a pid, a
  registered atom, or a `{:via, ...}` tuple. Returns `{:error, :not_found}`
  when a registered name doesn't currently point at a process; does not
  check process liveness for direct pids (`is_pid/1` alone is enough to
  succeed).
  """
  @spec resolve(server()) :: {:ok, pid()} | {:error, term()}
  def resolve(server) do
    resolve_server(server)
  end

  defp resolve_server(pid) when is_pid(pid) do
    {:ok, pid}
  end

  defp resolve_server({:via, _, _} = via) do
    case GenServer.whereis(via) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(name) when is_atom(name) do
    case GenServer.whereis(name) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(id) when is_binary(id) do
    {:error,
     {:invalid_server,
      "String IDs require an explicit Aikido instance lookup for #{inspect(id)}. Use the PID from the domain start action's reference, or pass an instance-scoped PID obtained from DurableServer lookup."}}
  end

  defp resolve_server(_) do
    {:error, :invalid_server}
  end

  # ---------------------------------------------------------------------------
  # Internal: Hierarchy
  # ---------------------------------------------------------------------------

  defp ensure_adopt_tag_available(state, tag) do
    case Map.get(state.children, tag) do
      nil -> :ok
      _child -> {:error, {:tag_in_use, tag}}
    end
  end

  defp resolve_adopt_child(pid, _state) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, pid}
    else
      {:error, :child_not_alive}
    end
  end

  defp resolve_adopt_child(id, state) when is_binary(id) do
    case Aikido.Durable.lookup(Aikido.durable_supervisor_name(state.aikido), id,
           partition: state.partition
         ) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :child_not_found}
    end
  end

  defp resolve_adopt_child(child, _state) do
    {:error, {:invalid_child, child}}
  end

  defp attach_parent(state, parent_ref) do
    cond do
      not is_nil(state.parent) ->
        {:error, :already_attached}

      not is_pid(parent_ref.pid) or parent_ref.pid == self() ->
        {:error, :invalid_parent}

      true ->
        next = state |> State.attach_parent(parent_ref) |> maybe_monitor_parent()
        notify_parent_of_startup(next)
        {:ok, next}
    end
  end

  defp maybe_monitor_parent(%State{parent: %ParentRef{pid: pid}} = state) when is_pid(pid) do
    Process.monitor(pid)
    state
  end

  defp maybe_monitor_parent(state) do
    state
  end

  defp notify_parent_of_startup(%State{parent: %ParentRef{} = parent} = state)
       when is_pid(parent.pid) do
    child_started =
      ChildStarted.new!(
        %{
          parent_id: parent.id,
          child_id: state.id,
          child_partition: state.partition,
          child_module: state.agent_module,
          tag: parent.tag,
          pid: self(),
          meta: parent.meta || %{}
        },
        source: "/agent/#{state.id}"
      )

    _ = cast(parent.pid, child_started)
    :ok
  end

  defp notify_parent_of_startup(_state) do
    :ok
  end

  defp handle_parent_down(
         %State{on_parent_death: :stop, parent: former_parent} = state,
         _pid,
         reason
       ) do
    state = emit_parent_died(state, former_parent, reason)
    stop_reason = wrap_parent_down_reason(reason)

    Logger.info(
      "AgentServer #{state.id} stopping: parent died (#{inspect(reason)}), wrapped stop_reason: #{inspect(stop_reason)}"
    )

    {:stop, stop_reason, %{state | status: :stopping}}
  end

  defp handle_parent_down(%State{on_parent_death: :continue} = state, _pid, reason) do
    {former_parent, orphaned_state} = transition_to_orphan(state, reason)
    orphaned_state = emit_parent_died(orphaned_state, former_parent, reason)

    Logger.info(
      "AgentServer #{state.id} continuing as orphan after parent #{former_parent.id} died (#{inspect(reason)})"
    )

    {:noreply, orphaned_state}
  end

  defp handle_parent_down(%State{on_parent_death: :emit_orphan} = state, _pid, reason) do
    {former_parent, orphaned_state} = transition_to_orphan(state, reason)
    orphaned_state = emit_parent_died(orphaned_state, former_parent, reason)
    orphaned_state = emit_identity_orphaned(orphaned_state, former_parent, reason)

    signal =
      Orphaned.new!(
        %{
          parent_id: former_parent.id,
          parent_pid: former_parent.pid,
          tag: former_parent.tag,
          meta: former_parent.meta || %{},
          reason: reason
        },
        source: "/agent/#{orphaned_state.id}"
      )

    case process_signal(orphaned_state, signal) do
      {:ok, new_state, _directives} -> {:noreply, new_state}
      {:error, committed_state, _reason} -> {:noreply, committed_state}
      {:stop, reason, new_state} -> {:stop, reason, %{new_state | status: :stopping}}
    end
  end

  defp emit_parent_died(%State{} = state, %ParentRef{} = former_parent, reason) do
    signal =
      ParentDied.new!(%{former_parent: former_parent, reason: reason},
        source: "/agent/#{state.id}"
      )

    dispatch_synthetic_signal(signal, state)
  end

  defp emit_parent_died(%State{} = state, _former_parent, _reason) do
    state
  end

  defp emit_identity_orphaned(%State{} = state, %ParentRef{} = former_parent, reason) do
    signal =
      IdentityOrphaned.new!(%{former_parent: former_parent, reason: reason},
        source: "/agent/#{state.id}"
      )

    dispatch_synthetic_signal(signal, state)
  end

  # Synthesize a signal locally and run it through the agent's own
  # `process_signal/2` pipeline so subscribers see it. Used by handlers
  # that mutate state outside the signal pipeline (DOWN handlers,
  # restart timers, adoption handlers) to give `subscribe/4` consumers
  # a subscribable channel for state-only transitions.
  #
  # Returns the post-pipeline `%State{}`. The caller composes it into
  # whatever return shape the surrounding handler needs (`{:noreply, _}`,
  # `{:reply, _, _}`, etc.). `:stop` directives from middleware are
  # collapsed to a state return — synthetic signals shouldn't terminate
  # the agent on their own.
  defp dispatch_synthetic_signal(signal, %State{} = state) do
    case process_signal(state, signal) do
      {:ok, new_state, _directives} -> new_state
      {:error, committed_state, _reason} -> committed_state
      {:stop, _reason, new_state} -> new_state
    end
  end

  defp handle_child_down(%State{} = state, pid, reason) do
    child =
      Enum.find_value(state.children, fn {_tag, child} -> if child.pid == pid, do: child end)

    {tag, state} = State.remove_child_by_pid(state, pid)

    if tag do
      Logger.debug("AgentServer #{state.id} child #{inspect(tag)} exited: #{inspect(reason)}")

      signal =
        ChildExit.new!(%{tag: tag, pid: pid, reason: reason},
          source: "/agent/#{state.id}"
        )

      if team_pid = child.meta[:team_pid] do
        if team_pid != self(), do: cast(team_pid, signal)
      end

      case process_signal(state, signal) do
        {:ok, new_state, _directives} -> {:noreply, new_state}
        {:error, committed_state, _reason} -> {:noreply, committed_state}
        {:stop, reason, new_state} -> {:stop, reason, %{new_state | status: :stopping}}
      end
    else
      {:noreply, state}
    end
  end

  # Wraps parent-down reasons so OTP treats them as clean shutdowns.
  # OTP only considers :normal, :shutdown, and {:shutdown, term} as "normal" exits.
  # All other reasons get logged as errors by the default GenServer logger.
  defp wrap_parent_down_reason(reason), do: {:shutdown, {:parent_down, reason}}

  defp transition_to_orphan(%State{parent: %ParentRef{} = former_parent} = state, reason) do
    orphaned_state =
      state
      |> State.orphan_parent()
      |> State.record_debug_event(:orphaned, %{
        former_parent_id: former_parent.id,
        tag: former_parent.tag,
        reason: reason
      })

    {former_parent, orphaned_state}
  end

  # ---------------------------------------------------------------------------
  # Internal: Telemetry
  # ---------------------------------------------------------------------------

  defp exec_directive_with_telemetry(directive, signal, state) do
    start_time = System.monotonic_time()
    directive_type = directive.__struct__ |> Module.split() |> List.last()

    metadata =
      %{
        agent_id: state.id,
        agent_module: state.agent_module,
        directive_type: directive_type,
        directive: directive,
        signal_id: signal.id,
        signal_type: signal.type,
        aikido_instance: state.aikido,
        aikido_partition: state.partition
      }

    emit_telemetry(
      [:aikido, :agent_server, :directive, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = Aikido.Directive.exec(directive, signal, state)

      emit_telemetry(
        [:aikido, :agent_server, :directive, :stop],
        %{duration: System.monotonic_time() - start_time},
        Map.merge(metadata, %{result: result_type(result)})
      )

      result
    catch
      kind, reason ->
        emit_telemetry(
          [:aikido, :agent_server, :directive, :exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, %{kind: kind, error: reason})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp result_type(:ok) do
    :ok
  end

  defp result_type({:stop, _}) do
    :stop
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end

  # Warn when {:stop, ...} is used with normal-looking reasons.
  # This indicates likely misuse - normal completion should use state.status instead.
  defp warn_if_normal_stop(reason, directive, state)
       when reason in [:normal, :completed, :ok, :done, :success] do
    directive_type = directive.__struct__ |> Module.split() |> List.last()

    Logger.warning(
      "AgentServer #{state.id} received {:stop, #{inspect(reason)}, ...} from directive #{directive_type}.

This is a HARD STOP: pending directives and async work will be lost,

For normal completion, set state.status to :completed/:failed instead and avoid returning {:stop, ...}.
External code should subscribe before dispatch, using AgentServer.call_until/5 to await terminal state.

{:stop, ...} should only be used for abnormal/framework-level termination.
"
    )
  end

  defp warn_if_normal_stop(_reason, _directive, _state) do
    :ok
  end
end
