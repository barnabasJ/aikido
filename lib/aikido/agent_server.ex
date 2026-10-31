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
  relationship is represented explicitly with `Aikido.Ownership.ParentRef`,
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

  ## Waiting for asynchronous work

  Handling a command can start asynchronous work. Its processing receipt does
  not mean that work has finished. For an AI agent, the opening signal starts
  a run; later model and tool result signals let its actions update the run state.

  This external-caller example assumes `server` is a running agent with
  `Aikido.AI.Extension` and a configured model. It waits for one particular AI run:

      request_id = Ash.UUIDv7.generate()

      signal =
        Aikido.Signal.new!("ai.react.ask", %{
          query: "Summarize this document...",
          request_id: request_id
        })

      selector = fn runtime ->
        case runtime.agent.state.ai do
          %{request_id: ^request_id, status: :completed, result: answer} ->
            {:ok, answer}

          %{request_id: ^request_id, status: :failed, error: reason} ->
            {:error, reason}

          _ ->
            :skip
        end
      end

      {:ok, answer} =
        AgentServer.call_until(server, signal, "ai.react.**", selector, timeout: 30_000)

  `call_until/5` subscribes before dispatching the opening signal. After matching
  signals are processed, the selector reads their resulting state. `:skip` keeps
  waiting; a tagged result finishes the one-shot subscription. There are no
  repeated state queries. Matching the request ID keeps other runs separate.

  Other workflows can expose their own completion state and selectors; the AI
  fields above are not required on every agent. Waiting is optional and belongs
  in an external caller, never inside a reducer or directive callback.

  Completing work does not stop the agent process. Intentional shutdown is a
  separate operation, supported by `%Aikido.Directives.Stop{reason: :normal}`.
  Its `exec/3` returns `{:stop, reason}`, ending the process and the remaining
  directive batch. Shutdown does not wait for outstanding work to finish; a
  waiting caller may receive `{:error, {:server_stopped, reason}}` instead of a
  task result. Clean shutdown still runs the stopping lifecycle path.

  ## Debugging

  AgentServer can record recent events in an in-memory ring buffer to help
  diagnose what happened inside a running agent. Capacity is configurable through
  `debug_max_events` and defaults to 500 events.

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
  the ownership action clears the current parent reference when the logical
  parent dies:

  - the ownership slice's `parent` becomes `nil`
  - the former parent is preserved in its `orphaned_from` attribute

  Partition lives on `%AgentServer.State{}`; parent bindings live in
  `Aikido.Ownership.Slice`. Actions reach the current values via
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

  alias Aikido.AgentServer.{Options, SignalRouter, State}
  alias Aikido.Ownership.ParentRef
  alias Aikido.Ownership.Child

  alias Aikido.AgentServer.Signals.{
    LifecycleReady,
    LifecycleStarting,
    LifecycleStopping,
    PartitionAssigned
  }

  alias Aikido.Config.Defaults
  alias Aikido.Signal
  alias Aikido.Signal.Router
  alias Aikido.Telemetry.Formatter
  @type server :: pid() | atom() | {:via, module(), term()} | String.t()
  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------
  @typedoc """
  Selector for `call/4` and `state/3`. Receives the full
  `%AgentServer.State{}`; the slice the user cares about lives at
  `state.agent.state`, under its configured own-state or mounted slice path. Must
  return a tagged `{:ok, _}` or `{:error, _}` tuple.

  Selectors run synchronously in the agent process. A raising selector is
  caught and surfaces to the caller as
  `{:error, {:selector_raised, exception, stacktrace}}`.

  No `:skip` return — the caller is blocking, so "skip" has no meaning.
  Use `subscribe/4` for the ambient pattern that supports `:skip`.
  """
  @type call_selector :: (State.t() -> {:ok, term()} | {:error, term()})
  @typedoc "Signal, returned effect descriptors and processing error available to subscription projections."
  @type execution_event :: %{signal: Signal.t(), directives: [struct()], error: term()}
  @typedoc """
  Selector for `subscribe/4`. Same calling convention as `call_selector/0`,
  with one extra return value: `:skip` keeps the subscription alive and
  delivers nothing to the subscriber. A two-argument selector additionally receives
  the processed signal, returned directives and processing error.
  """
  @type subscribe_selector ::
          (State.t() -> {:ok, term()} | {:error, term()} | :skip)
          | (State.t(), execution_event() -> {:ok, term()} | {:error, term()} | :skip)
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

    with {:ok, pid} <- resolve(server) do
      signal = Aikido.Signal.capture_tracing(signal)
      emit_signal_dispatch(signal, pid, :call)

      GenServer.call(
        pid,
        {:signal_with_selector, signal, selector},
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

    tracers = command_tracers(command, opts)

    transfer = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers)

    {waiter, monitor} =
      spawn_monitor(fn ->
        Ash.ProcessHelpers.transfer_context(transfer)
        result = wait_for_command_result(server, command, pattern, selector, timeout)
        send(caller, {request, result})
      end)

    await_command_waiter(waiter, monitor, request, timeout)
  end

  defp command_tracers(command, opts) do
    if is_struct(command, Signal),
      do: Aikido.Signal.tracers(command),
      else:
        Enum.uniq(
          List.wrap(Keyword.get(opts, :tracer)) ++
            List.wrap(Application.get_env(:ash, :tracer)) ++
            List.wrap(Aikido.Telemetry.Config.tracer())
        )
  end

  defp await_command_waiter(waiter, monitor, request, timeout) do
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
    with {:ok, pid} <- resolve(server),
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
    with {:ok, pid} <- resolve(server) do
      signal = Aikido.Signal.capture_tracing(signal)
      emit_signal_dispatch(signal, pid, :cast)
      GenServer.cast(pid, {:signal, signal})
    end
  end

  defp emit_signal_dispatch(signal, pid, delivery) do
    emit_telemetry(
      [:aikido, :agent_server, :signal, :sent],
      %{system_time: System.system_time()},
      %{signal_type: signal.type, signal_id: signal.id, target: pid, delivery: delivery}
    )
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

    with {:ok, pid} <- resolve(server) do
      GenServer.call(pid, {:read_state_with_selector, selector}, timeout)
    end
  end

  @doc """
  Subscribe to signals matching `pattern`, with a selector deciding what
  the subscriber sees.

  A two-argument selector also receives an execution event containing the original
  `:signal`, returned `:directives` and processing `:error` (nil on success).
  Project only the data the subscriber needs; signals and directives can contain
  private application data. This adds no state mutation or replay behavior.

  The selector runs after the outermost middleware unwinds (same hook
  point as `call/4`). Returning `:skip` keeps the subscription silent and
  alive; `{:ok, _}` / `{:error, _}` dispatches the result to the
  subscriber. With `once: true`, the subscription is removed after the
  first non-`:skip` selector return.

  Patterns are compiled by `Aikido.Signal.Router` and have identical
  semantics to `signal_routes/1` declarations: literals (`"work.start"`),
  single-segment wildcards (`"work.*"` matches any single segment after
  `"work."`), and the multi-segment wildcard (`"audit.**"`, or `"**"`
  alone to match every signal regardless of segment count).

  Direct process delivery sends
  `{:aikido_subscription, sub_ref, %{signal_type: type, result: result}}`
  to the caller.

  ## Options

  - `:target` — recipient PID (default `self()`)
  - `:once` — boolean, if true unsubscribe after first non-`:skip` fire (default `false`)
  - `:timeout` — ms to wait for the registration reply
    (default `Defaults.agent_server_call_timeout_ms/0`)

  ## Returns

  - `{:ok, sub_ref}` — subscription registered; pass `sub_ref` to `unsubscribe/2`
  - `{:error, reason}` — pattern invalid or server lookup failed
  """
  @spec subscribe(server(), String.t(), subscribe_selector(), keyword()) ::
          {:ok, reference()} | {:error, term()}
  def subscribe(server, pattern, selector, opts \\ [])
      when is_binary(pattern) and (is_function(selector, 1) or is_function(selector, 2)) do
    with {:ok, options} <-
           Spark.Options.validate(opts,
             target: [type: :pid, default: self()],
             once: [type: :boolean, default: false],
             timeout: [
               type: :non_neg_integer,
               default: Defaults.agent_server_call_timeout_ms()
             ]
           ),
         {:ok, pid} <- resolve(server) do
      GenServer.call(
        pid,
        {:subscribe, pattern, selector, options[:target], self(), options[:once]},
        options[:timeout]
      )
    end
  end

  @doc """
  Cancel a subscription created via `subscribe/4`.

  Idempotent — unknown refs are silently ignored.
  """
  @spec unsubscribe(server(), reference()) :: :ok | {:error, term()}
  def unsubscribe(server, sub_ref) when is_reference(sub_ref) do
    with {:ok, pid} <- resolve(server) do
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

    case resolve(server) do
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

    with {:ok, pid} <- resolve(server) do
      case GenServer.call(pid, {:get_child_pid, child_tag}) do
        {:ok, child_pid} -> {:ok, child_pid}
        :not_found -> subscribe_and_await_child(pid, child_tag, timeout)
      end
    end
  end

  defp subscribe_and_await_child(pid, child_tag, timeout) do
    selector = fn %State{} = state ->
      case Map.get(Aikido.Ownership.children(state), child_tag) do
        %Child{pid: child_pid} when is_pid(child_pid) -> {:ok, child_pid}
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
  # the ownership slice but our subscriber wasn't registered in time to
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
    with {:ok, pid} <- resolve(server) do
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

  - `:limit` - Maximum number of retained events to return (default: all retained events)

  ## Examples

      {:ok, events} = AgentServer.recent_events(pid, limit: 10)
  """
  @spec recent_events(server(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recent_events(server, opts \\ []) do
    with {:ok, pid} <- resolve(server) do
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
    case resolve(server) do
      {:ok, pid} -> Process.alive?(pid)
      {:error, _} -> false
    end
  end

  @doc """
  Low-level primitive: imperatively attach a running agent to a parent ref.

  Used internally by the `%Aikido.Directives.AdoptChild{}` executor to
  route the parent attachment through the child's ownership slice.
  Prefer booting the child with `parent: parent_ref` in its AgentServer
  options (the ownership configuration action consumes it) so `post_init` can emit
  `aikido.agent.child.started` declaratively — this function exists for
  the explicit-adoption-at-runtime path only.
  """
  @spec adopt_parent(server(), ParentRef.t()) ::
          {:ok, %{id: String.t(), agent_module: module(), partition: term() | nil}}
          | {:error, term()}
  def adopt_parent(server, %ParentRef{} = parent_ref) do
    with {:ok, pid} <- resolve(server) do
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
  ownership slice before returning.

  Prefer returning a `%Aikido.Directives.AdoptChild{}` from an action
  when the initiator is already inside an agent — this function is for
  external callers (tests, supervisors, LiveView mounts) that need to
  attach children from outside the signal/directive pipeline.
  """
  @spec adopt_child(server(), pid() | String.t(), term(), map()) ::
          {:ok, pid()} | {:error, term()}
  def adopt_child(server, child, tag, meta \\ %{}) do
    with {:ok, parent_pid} <- resolve(server),
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
    with {:ok, pid} <- resolve(server) do
      try do
        GenServer.call(pid, {:stop_child, tag, reason})
      catch
        :exit, {:noproc, _} -> {:error, :not_found}
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, reason}
      end
    end
  end

  @doc false
  def prepare_stop(server, reason \\ :normal, scope \\ %{}) do
    options =
      case scope do
        %{context: context} -> Ash.Scope.to_opts(scope, context: context)
        _ -> Ash.Scope.to_opts(scope)
      end

    signal =
      LifecycleStopping.new!(%{reason: reason}, scope: Map.new(options))
      |> Aikido.Signal.capture_tracing()

    with {:ok, pid} <- resolve(server) do
      GenServer.call(pid, {:prepare_stop, signal})
    end
  end

  # ---------------------------------------------------------------------------
  # ---------------------------------------------------------------------------
  @impl true
  def init(raw_opts) do
    opts =
      if is_map(raw_opts) do
        Map.to_list(raw_opts)
      else
        raw_opts
      end

    {initialization_options, opts} = Keyword.pop(opts, :initialization_options, [])
    initialization_options = Map.new(initialization_options)

    initialization_options =
      Ash.Scope.to_opts(initialization_options,
        context: Map.get(initialization_options, :context, %{})
      )

    activation_scope = Map.new(initialization_options)
    {restored_agent, opts} = Keyword.pop(opts, :restored_agent)

    with {:ok, options} <- Options.new(opts),
         agent_module = options.agent_module,
         chain = build_middleware_chain(agent_module, options),
         agent = restored_agent || build_agent(agent_module, options, initialization_options),
         {:ok, state} <-
           State.from_options(options, agent_module, agent, middleware_chain: chain) do
      # Lifecycle observers see restored domain state before schedules start.
      signal_router = SignalRouter.build(state)
      state = %{state | signal_router: signal_router}

      ownership =
        Aikido.Ownership.Signals.Configure.new!(
          %{parent: options.parent, on_parent_death: options.on_parent_death},
          source: "/agent/#{state.id}",
          scope: activation_scope
        )
        |> Aikido.Signal.capture_tracing()

      with {:ok, state, _} <- process_signal(state, ownership),
           {:ok, state, _} <-
             process_signal(state, lifecycle_starting_signal(state, activation_scope)) do
        state = emit_through_chain(state, partition_assigned_signal(state, activation_scope))
        {:ok, state, {:continue, {:post_init, activation_scope}}}
      else
        {:error, _, reason} -> {:stop, reason}
        {:stop, reason, _} -> {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp build_agent(agent_module, %Options{id: id, initial_state: state}, initialization_options) do
    agent_module
    |> Ash.ActionInput.for_action(:initialize, %{id: id, state: state}, initialization_options)
    |> Ash.run_action!(initialization_options)
  end

  defp lifecycle_starting_signal(%State{} = state, scope) do
    LifecycleStarting.new!(%{}, source: "/agent/#{state.id}", scope: scope)
    |> Aikido.Signal.capture_tracing()
  end

  defp lifecycle_ready_signal(%State{} = state, scope) do
    LifecycleReady.new!(%{}, source: "/agent/#{state.id}", scope: scope)
    |> Aikido.Signal.capture_tracing()
  end

  defp lifecycle_stopping_signal(%State{} = state, reason, %Signal{} = input) do
    LifecycleStopping.new!(%{reason: reason},
      source: "/agent/#{state.id}",
      scope: Signal.ctx(input),
      tracer_context: Signal.tracer_context(input)
    )
  end

  defp lifecycle_stopping_signal(%State{} = state, reason) do
    LifecycleStopping.new!(%{reason: reason}, source: "/agent/#{state.id}")
  end

  defp partition_assigned_signal(%State{} = state, scope) do
    PartitionAssigned.new!(%{partition: state.partition},
      source: "/agent/#{state.id}",
      scope: scope
    )
    |> Aikido.Signal.capture_tracing()
  end

  @impl true
  def handle_continue({:post_init, scope}, state) do
    state = emit_through_chain(state, lifecycle_ready_signal(state, scope))
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
          stopping = lifecycle_stopping_signal(executed_state, stop_reason, signal)

          case prepare_graceful_stop(executed_state, stop_reason, stopping) do
            {:ok, stopped_state} ->
              {:stop, stop_reason, invoke_selector(selector, stopped_state), stopped_state}

            {:error, committed_state, reason} ->
              {:stop, stop_reason, {:error, reason}, %{committed_state | status: :stopping}}
          end
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

  def handle_call({:prepare_stop, %Signal{} = signal}, _from, %State{} = state) do
    signal = %{signal | source: "/agent/#{state.id}"}

    case prepare_graceful_stop(state, signal.data.reason, signal) do
      {:ok, stopped_state} -> {:reply, :ok, stopped_state}
      {:error, committed_state, reason} -> {:reply, {:error, reason}, committed_state}
    end
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
    case Map.get(Aikido.Ownership.children(state), child_tag) do
      %Child{pid: pid} when is_pid(pid) -> {:reply, {:ok, pid}, state}
      _ -> {:reply, :not_found, state}
    end
  end

  def handle_call(
        {:subscribe, pattern, selector, target, caller_pid, once?},
        _from,
        %State{} = state
      )
      when is_binary(pattern) and (is_function(selector, 1) or is_function(selector, 2)) and
             is_pid(caller_pid) and
             is_boolean(once?) do
    case Router.validate_pattern(pattern) do
      {:ok, _} ->
        sub_ref = make_ref()
        monitor_ref = Process.monitor(caller_pid)

        entry = %{
          pattern_compiled: Router.compile_pattern(pattern),
          selector: selector,
          target: target,
          monitor_ref: monitor_ref,
          once: once?
        }

        {:reply, {:ok, sub_ref},
         %{state | signal_subscribers: Map.put(state.signal_subscribers, sub_ref, entry)}}

      {:error, reason} ->
        {:reply, {:error, {:invalid_pattern, reason}}, state}
    end
  end

  def handle_call({:adopt_parent, %ParentRef{} = parent_ref}, from, %State{} = state) do
    signal =
      Aikido.Ownership.Signals.AttachParent.new!(%{parent: parent_ref},
        source: "/agent/#{state.id}"
      )

    selector = fn runtime ->
      {:ok, %{id: runtime.id, agent_module: runtime.agent_module, partition: runtime.partition}}
    end

    handle_call({:signal_with_selector, signal, selector}, from, state)
  end

  def handle_call({:stop_child, tag, reason}, from, %State{} = state) do
    signal =
      Aikido.Ownership.Signals.StopChildRequested.new!(%{tag: tag, reason: reason},
        source: "/agent/#{state.id}"
      )

    handle_call({:signal_with_selector, signal, fn _runtime -> :ok end}, from, state)
  end

  def handle_call(_msg, _from, state) do
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast({:adopt_parent, %ParentRef{} = parent_ref}, %State{} = state) do
    signal =
      Aikido.Ownership.Signals.AttachParent.new!(%{parent: parent_ref},
        source: "/agent/#{state.id}"
      )

    handle_cast({:signal, signal}, state)
  end

  # Initial activation can outlive its parent before DurableServer resolves the
  # saved logical binding. Repair only an untouched binding; an existing parent
  # or completed orphan transition must retain its current lifecycle decision.
  def handle_cast(
        {:ensure_initial_parent, %ParentRef{} = parent_ref},
        %State{} = state
      ) do
    signal =
      Aikido.Ownership.Signals.AttachParent.new!(%{parent: parent_ref, initial_only?: true},
        source: "/agent/#{state.id}"
      )

    handle_cast({:signal, signal}, state)
  end

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
      {:ok, new_state, _directives} ->
        {:noreply, new_state}

      {:error, committed_state, _reason} ->
        {:noreply, committed_state}

      {:stop, reason, new_state} ->
        {:stop, reason, finish_signal_stop(new_state, reason, signal)}
    end
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:scheduled_signal, %Signal{} = signal}, state) do
    case process_signal(state, signal) do
      {:ok, new_state, _directives} ->
        {:noreply, new_state}

      {:error, committed_state, _reason} ->
        {:noreply, committed_state}

      {:stop, reason, new_state} ->
        {:stop, reason, finish_signal_stop(new_state, reason, signal)}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Aikido.Cron.Messages.from_down(state, ref, pid, reason) do
      %Signal{} = signal ->
        handle_info({:signal, signal}, state)

      nil ->
        state = drop_dead_subscriber(state, ref)

        dispatch_owned_process_exit(state, ref, pid, reason)
    end
  end

  def handle_info({:signal, %Signal{} = signal}, state) do
    case process_signal(state, signal) do
      {:ok, new_state, _directives} ->
        {:noreply, new_state}

      {:error, committed_state, _reason} ->
        {:noreply, committed_state}

      {:stop, reason, new_state} ->
        {:stop, reason, finish_signal_stop(new_state, reason, signal)}
    end
  end

  def handle_info(message, state) do
    case Aikido.Notifications.Receiver.receive_message(message, state.agent) do
      {:ok, signal} ->
        handle_info({:signal, signal}, state)

      :ignore ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Agent #{state.id} rejected notification: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    # Callerless shutdown has no authority to borrow from an earlier activation.
    # It can only perform cleanup permitted by the application's current policies.
    stopping = lifecycle_stopping_signal(state, reason)
    _state = finish_stop(state, reason, stopping)
    :ok
  end

  defp finish_signal_stop(state, reason, signal) do
    finish_stop(state, reason, lifecycle_stopping_signal(state, reason, signal))
  end

  defp finish_stop(state, reason, stopping) do
    case prepare_graceful_stop(state, reason, stopping) do
      {:ok, stopped_state} ->
        stopped_state

      {:error, committed_state, error} ->
        Logger.error("Agent #{state.id} stop cleanup failed: #{inspect(error)}")
        %{committed_state | status: :stopping}
    end
  end

  defp prepare_graceful_stop(%State{status: :stopping} = state, _reason, _signal),
    do: {:ok, state}

  defp prepare_graceful_stop(state, reason, signal) do
    if clean_shutdown?(reason) do
      case process_signal(state, signal) do
        {:ok, committed_state, _directives} -> {:ok, %{committed_state | status: :stopping}}
        {:stop, _reason, committed_state} -> {:ok, %{committed_state | status: :stopping}}
        {:error, committed_state, error} -> {:error, committed_state, error}
      end
    else
      {:ok, %{state | status: :stopping}}
    end
  catch
    kind, error -> {:error, state, {:stop_cleanup_failed, kind, error}}
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
  # Directive failures retain the adopted state and stop the remaining batch.
  # Uncaught reducer raises propagate up; the `handle_call` handler catches them
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
    tracers = Aikido.Signal.tracers(signal, state.aikido)
    previous = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers)
    incoming = Map.new(tracers, &{&1, Map.get(Aikido.Signal.tracer_context(signal), &1)})
    Ash.ProcessHelpers.transfer_context(incoming)
    signal = if tracers == [], do: signal, else: Aikido.Signal.put(signal, :tracer, tracers)

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

    emit_telemetry(
      [:aikido, :agent_server, :signal, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = run_middleware_and_adopt_agent(signal, state)

      emit_telemetry(
        [:aikido, :agent_server, :signal, :stop],
        %{duration: System.monotonic_time() - start_time},
        Map.merge(metadata, signal_stop_metadata_for(result))
      )

      execute_signal_effects(result, signal)
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

  defp execute_signal_effects({:ok, state, directives}, signal) do
    directives
    |> execute_directives(signal, state)
    |> notify_after_effects(signal, directives)
  end

  defp execute_signal_effects({:error, state, reason}, signal) do
    {:error, fire_subscribers(state, signal, [], reason), reason}
  end

  defp notify_after_effects({:ok, state}, signal, directives),
    do: {:ok, fire_subscribers(state, signal, directives, nil), directives}

  # Shutdown is observed through the process monitor, not a terminal state snapshot.
  defp notify_after_effects({:stop, reason, state}, _signal, _directives),
    do: {:stop, reason, state}

  defp notify_after_effects({:error, state, reason}, signal, directives),
    do: {:error, fire_subscribers(state, signal, directives, reason), reason}

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
  defp run_middleware_and_adopt_agent(
         %Signal{} = signal,
         %State{middleware_chain: chain} = state,
         opts \\ []
       )
       when is_function(chain, 2) do
    ctx =
      build_signal_ctx(signal, state)
      |> Map.put(:__allow_unhandled__, Keyword.get(opts, :allow_unhandled?, false))

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
  # Mirrors agent-state adoption in `run_middleware_and_adopt_agent/2` and
  # runs returned directives inline so emitted signals reach observers.
  #
  # Like the user-signal path, subscribers fire after the outermost
  # middleware unwinds and directives have executed.
  defp emit_through_chain(%State{} = state, %Signal{} = signal) do
    with_signal_span(state, signal, fn signal ->
      case run_middleware_and_adopt_agent(signal, state, allow_unhandled?: true) do
        {:ok, next, directives} ->
          executed =
            case execute_directives(directives, signal, next) do
              {:ok, state} -> state
              {:stop, _reason, state} -> state
              {:error, state, _reason} -> state
            end

          fire_subscribers(executed, signal, directives, nil)

        {:error, next, reason} ->
          fire_subscribers(next, signal, [], reason)
      end
    end)
  end

  defp build_signal_ctx(%Signal{} = signal, %State{} = state) do
    signal_ctx = Aikido.Signal.ctx(signal)

    base = %{
      agent: state.agent,
      agent_module: state.agent_module,
      agent_id: state.id,
      agent_pid: self(),
      partition: state.partition,
      parent: Aikido.Ownership.parent(state),
      orphaned_from: Aikido.Ownership.orphaned_from(state),
      aikido: state.aikido,
      skip_schedules: state.skip_schedules,
      __signal_router__: state.signal_router
    }

    Map.merge(signal_ctx, base)
  end

  @doc false
  # Inline directive loop. Each directive returns `:ok` (bounded I/O;
  # for async effects, spawn a task and emit a signal when done — see
  # the Aikido.Directive docs). `{:stop, reason}` aborts the batch and
  # propagates as `{:stop, reason, state}` to the GenServer. A failing callback
  # stops the batch with `{:error, state, reason}`, preserving adopted state.
  #
  # The directive contract has no state slot in its return value:
  # directives mutate no state. This runtime loop records debug events.
  # Feature slices adopt effect results through subsequent routed signals.
  @spec execute_directives([struct()], Signal.t(), State.t()) ::
          {:ok, State.t()} | {:stop, term(), State.t()} | {:error, State.t(), term()}
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

    result =
      try do
        exec_directive_with_telemetry(directive, signal, state)
      catch
        kind, reason ->
          Logger.error("""
          Directive execution failed for #{state.id}: #{inspect(kind)} #{inspect(reason)}
          #{Exception.format_stacktrace(__STACKTRACE__)}
          """)

          {:error, reason}
      end

    case result do
      :ok ->
        execute_directives(rest, signal, state)

      {:stop, reason} ->
        {:stop, reason, state}

      {:error, reason} ->
        {:error, state, reason}
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

  defp fire_subscribers(%State{} = state, %Signal{type: type} = signal, directives, error) do
    event = %{signal: signal, directives: directives, error: error}
    Aikido.Inspector.observe(state, event)

    Enum.reduce(state.signal_subscribers, state, fn {sub_ref, entry}, acc_state ->
      if Router.matches_compiled?(type, entry.pattern_compiled) do
        fire_matching_subscriber(acc_state, sub_ref, entry, event)
      else
        acc_state
      end
    end)
  end

  defp fire_matching_subscriber(acc_state, sub_ref, entry, event) do
    case invoke_subscription_selector(entry.selector, acc_state, event) do
      :skip ->
        acc_state

      {:ok, _value} = fire ->
        deliver_subscription_result(acc_state, sub_ref, entry, event.signal, fire)

      {:error, _reason} = fire ->
        deliver_subscription_result(acc_state, sub_ref, entry, event.signal, fire)
    end
  end

  defp invoke_subscription_selector(selector, state, _event) when is_function(selector, 1),
    do: invoke_selector(selector, state)

  defp invoke_subscription_selector(selector, state, event) do
    selector.(state, event)
  rescue
    exception -> {:error, {:selector_raised, exception, __STACKTRACE__}}
  end

  defp deliver_subscription_result(acc_state, sub_ref, entry, signal, fire) do
    send(entry.target, {:aikido_subscription, sub_ref, %{signal_type: signal.type, result: fire}})

    if entry.once do
      remove_subscriber(acc_state, sub_ref)
    else
      acc_state
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
        {:error, :no_matching_route}

      {:error, reason} ->
        {:error, reason}
    end
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
    compile_mw = Aikido.Agent.Info.middleware(agent_module)
    all_entries = compile_mw ++ runtime_mw
    compose_chain(all_entries, &route_and_apply_reducers/2)
  end

  defp normalize_entry({mod, opts}) when is_atom(mod) and is_map(opts) do
    {mod, opts}
  end

  defp normalize_entry(mod) when is_atom(mod) do
    {mod, %{}}
  end

  defp compose_chain(entries, reducer_step) do
    Enum.reduce(Enum.reverse(entries), reducer_step, fn entry, acc_next ->
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
  defp route_and_apply_reducers(%Signal{} = signal, ctx) do
    case route_to_actions(ctx.__signal_router__, signal) do
      {:ok, targets} ->
        apply_actions(signal, ctx, targets)

      {:error, :no_matching_route} when ctx.__allow_unhandled__ ->
        {:ok, ctx, []}

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
    case Ash.transact(ctx.agent_module, fn -> stage_actions!(signal, ctx, targets) end,
           return_notifications?: true,
           tenant: Map.get(ctx, :tenant)
         ) do
      {:ok, {proposed, notifications, directives}, nested_notifications} ->
        notices =
          Enum.flat_map(nested_notifications ++ notifications, fn
            %Ash.Notifier.Notification{for: []} -> []
            notification -> [%Aikido.Directives.Notify{notification: notification}]
          end)

        {:ok, proposed, notices ++ directives}

      {:error, error} ->
        {:error, ctx, error}
    end
  rescue
    error -> {:error, ctx, Ash.Error.to_error_class(error)}
  end

  defp stage_actions!(signal, ctx, targets) do
    targets
    |> Enum.reduce_while({:ok, ctx, [], []}, fn target, accumulated ->
      case apply_action_at_mounted_paths(target, signal, accumulated) do
        {:ok, _, _, _} = result -> {:cont, result}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, proposed, notifications, directives} -> {proposed, notifications, directives}
      {:error, reason} -> raise Ash.Error.to_error_class(reason)
    end
  end

  defp apply_action_at_mounted_paths({reference, params}, signal, {:ok, ctx, _, _} = accumulated) do
    ctx.agent_module
    |> action_mount_paths(reference)
    |> Enum.reduce_while(accumulated, fn path, {:ok, current, notifications, effects} ->
      with {:ok, result} <- run_action(reference, params, signal, current, path),
           {:ok, current, notices} <- adopt_action_result(current, result, path, signal) do
        {:cont, {:ok, current, notifications ++ notices, effects ++ result.directives}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp action_mount_paths(agent_module, reference) do
    agent_module
    |> Aikido.Agent.Info.slice_paths_for_action()
    |> Map.get(reference, [Spark.Dsl.Extension.get_opt(agent_module, [:agent], :path)])
  end

  defp adopt_action_result(ctx, result, path, signal) do
    if is_nil(result.changes) || result.changes == %{} do
      {:ok, ctx, []}
    else
      context = Map.put(Map.get(ctx, :context) || %{}, :aikido, Map.put(ctx, :signal, signal))
      scope = Ash.Scope.to_opts(ctx, context: context)

      with {:ok, agent, notifications} <-
             Aikido.Agent.StateChanges.apply_changes(ctx.agent, path, result.changes, scope) do
        adopted = %{ctx | agent: agent}

        adopted =
          Map.merge(adopted, %{
            parent: Aikido.Ownership.parent(adopted),
            orphaned_from: Aikido.Ownership.orphaned_from(adopted)
          })

        {:ok, adopted, notifications}
      end
    end
  end

  defp run_action({resource, name} = reference, params, signal, ctx, path) do
    arguments = reducer_arguments(reference, params, signal, ctx, path)
    options = reducer_scope_options(params, signal, ctx, path)

    resource
    |> Ash.ActionInput.for_action(
      name,
      arguments,
      Keyword.put(options, :skip_unknown_inputs, [:*])
    )
    |> Ash.run_action(options)
    |> cast_reducer_result()
  end

  defp reducer_arguments({resource, name}, params, signal, ctx, path) do
    definition = Ash.Resource.Info.action(resource, name)
    state = Map.get(ctx.agent.state, path, %{})

    payload =
      case get_in(Spark.Dsl.Extension.get_persisted(resource, :aikido_union_reducers, %{}), [
             name,
             signal.type
           ]) do
        nil -> params
        variant -> %Ash.Union{type: variant, value: params}
      end

    if Enum.any?(definition.arguments, &(&1.name == :data)) &&
         name not in Spark.Dsl.Extension.get_persisted(resource, :aikido_flat_reducers, []),
       do: %{data: payload, state: state},
       else: Map.put(params || %{}, :state, state)
  end

  defp reducer_scope_options(params, signal, ctx, path) do
    runtime =
      Map.merge(ctx, %{
        signal: %{signal | data: params},
        slice_path: path,
        slice_config: Map.get(Aikido.Agent.Info.mount_config_map(ctx.agent_module), path, %{})
      })

    Ash.Scope.to_opts(ctx, context: Map.put(Map.get(ctx, :context) || %{}, :aikido, runtime))
  end

  defp cast_reducer_result({:ok, %Aikido.Types.ActionResult{} = result}),
    do: result |> Map.from_struct() |> Aikido.Types.ActionResult.new()

  defp cast_reducer_result({:ok, result}), do: Aikido.Types.ActionResult.new(result)
  defp cast_reducer_result(error), do: error

  # Routing failures short-circuit the chain before directives run.
  # Log them here so operators can identify signals without a valid route.
  defp log_routing_error(ctx, %{message: message}) do
    Logger.debug("Agent #{Map.get(ctx, :agent_id, "unknown")} [routing]: #{message}")
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
  def resolve(pid) when is_pid(pid) do
    {:ok, pid}
  end

  def resolve({:via, _, _} = via) do
    case GenServer.whereis(via) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  def resolve(name) when is_atom(name) do
    case GenServer.whereis(name) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  def resolve(id) when is_binary(id) do
    {:error,
     {:invalid_server,
      "String IDs require an explicit Aikido instance lookup for #{inspect(id)}. Use the PID from the domain start action's reference, or pass an instance-scoped PID obtained from DurableServer lookup."}}
  end

  def resolve(_) do
    {:error, :invalid_server}
  end

  # ---------------------------------------------------------------------------
  # Internal: Hierarchy
  # ---------------------------------------------------------------------------

  defp ensure_adopt_tag_available(state, tag) do
    case Map.get(Aikido.Ownership.children(state), tag) do
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

  defp dispatch_owned_process_exit(state, ref, pid, reason) do
    case Aikido.Ownership.Messages.from_down(state, ref, pid, reason) do
      %Signal{} = signal -> handle_info({:signal, signal}, state)
      nil -> {:noreply, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: Telemetry
  # ---------------------------------------------------------------------------

  defp exec_directive_with_telemetry(directive, signal, state) do
    start_time = System.monotonic_time()
    metadata = directive_metadata(directive, signal, state)

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

  defp directive_metadata(directive, signal, state) do
    directive_type = directive.__struct__ |> Module.split() |> List.last()

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
end
