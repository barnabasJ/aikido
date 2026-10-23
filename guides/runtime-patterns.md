# Choosing a Runtime Pattern

Use Ash agent resources (`Aikido.Agent.Extension`) for typed agent state and domain actions.
Add `Aikido.Team.Extension` when an agent manages a named topology of workers or nested
teams. Add `Aikido.AI.Extension` for model turns and dynamically supplied tools.

The default `Aikido` supervision tree uses DurableServer for activation, snapshots,
and recovery. Configure its backend with `durable: [...]`. Use `Aikido.Durable`
for a separately configured DurableServer namespace; it delegates process ownership
and storage to DurableServer. Local EKV options can be supplied directly, for example
`durable: [data_dir: "path/to/fresh-store", ekv_options: [shards: 8]]`.
The existing one-shard default is retained for compatibility. The example app can select
eight shards with `AIKIDO_EXAMPLES_EKV_SHARDS=8`. EKV records the shard count on disk;
changing it requires a fresh store or a separate migration, not reopening existing
files with a different count. Explicit `backend` configurations own their own options.
`SpawnAgent.start_options` forwards native DurableServer activation options,
including `timeout`. This bounds the supervised activation task's wait rather than
blocking the parent. The large quicksort example uses a 30-second activation budget;
storage operations keep their own deadlines, and rejected starts still return
failure signals.

Activate agents through their generated domain `start` action. Adding `Aikido`
to the application supervision tree starts one shared runtime. Its DurableServer
dynamic supervisor owns all agent processes in that runtime; starting an agent
does not start another supervisor tree or link the agent to its caller.
The separate process supervisor handles non-agent children from `Spawn` directives.
Explicitly starting a second named runtime creates another shared tree.
`restart?` controls automatic crash recovery, while the agent's `persistence`
setting controls whether stopping retains its snapshot.

For a named runtime, declare `use Aikido, otp_app: :my_app` on a module and put
that module in your supervision tree. It supplies only `child_spec/1` and
`start_link/1` (with optional arguments). Use the domain for agents and `Aikido`
for runtime configuration:

```elixir
agent = MyApp.Agents.worker_start!(%{id: "worker"})
MyApp.Agents.worker_inspect!(agent)
Aikido.config(MyApp.Runtime, max_tasks: 2_000)
Aikido.Instance.Info.instance_options(MyApp.Runtime)
```

`use Aikido` forwards native Spark options, including custom extensions and
fragments, to its instance host. `use Aikido.Directive` also accepts native Spark
options while retaining Ash's typed-struct DSL and the directive behaviour.

Spark validates and stores the instance configuration. The Info module reads
those options; `Aikido.config/2` combines application configuration and runtime
overrides. Instance modules do not generate lifecycle, persistence, debug or
configuration accessor wrappers. Agent lifecycle implementations call
`Aikido.Durable` directly; there is no separate lifecycle facade on `Aikido`.
Use `Aikido.Debug` for runtime diagnostics.

`Aikido.Agent` holds immutable identity and state and offers a convenience macro
for the Ash resource host. AgentServer routes signals to native Ash reducers and
applies their returned state before executing directives. `Aikido.AgentServer`
is the runtime callback implementation hosted by DurableServer. Configure
`persistence :temporary` to delete snapshots on stop. Actions are pure: they
return state transitions and directives without performing side effects. All
side effects belong in directives; results return through signals.

Choose a root `id` explicitly when an application must recover the same logical
execution, for example `"workflow/#{workflow_id}/review"`. Starting a stopped
permanent agent with that same ID restores its snapshot; a new workflow execution
should receive a different root ID. Root IDs share a namespace within their
Aikido instance and partition, so the application must choose distinct roots.

`Aikido.Agent.child_id(parent_id, child_name)` derives deterministic child IDs.
For example, a reviewer beneath `workflow/42` is `workflow/42/reviewer`, and its
helper is `workflow/42/reviewer/helper`. Names are escaped as individual path
components: the name `"reviewer/helper"` becomes `reviewer%2Fhelper`, distinct from
that nested hierarchy. SpawnAgent uses this derivation unless an ID is supplied
explicitly. Team members follow their declared ownership ancestry. A child's
stable ID is independent of its PID and of activation attempts.

Recovery resolves saved parents within the same DurableServer pool and partition.
If a saved parent is unavailable and `on_parent_death: :stop` applies, the child
stops instead of continuing as an unowned agent. Permanent snapshots retain the
logical parent binding so a later explicit activation can reconnect it; temporary
snapshots are deleted on that stop.

Keep completion requirements and hook planning visible as separate steps in a
reducer rather than calling a helper that combines both:

```elixir
result
|> Aikido.AiReact.RunState.resolve_run_outcome(input)
|> Aikido.AiReact.HookQueue.queue_event_hooks_if_changed(input, :after_tool, payload)
```

The ReAct helpers have distinct owners:

- `RunState` initializes a run, resolves its proposed outcome and clears finished-run data.
- `TodoRequirements` evaluates blocking todos; it does not execute or complete them.
- `Conversation` owns message history and its cached token counts.
- `ConversationHandoff` plans a model-written replacement conversation.
- `HookQueue` orders hook events and releases their pending effects.
- `RunCaller` binds a run to its actor and tenant.
- `CancellableTask` owns supervised I/O attempts, deadlines, retries and cleanup.
- `ModelStream` batches deltas from a ReqLLM response stream.

Helpers follow the same style: pure transformations compose through pipelines,
and fallible operations compose through `with`. For example,
`Aikido.Slice.Config.cast_config/2` casts supplied configuration without reading
application configuration; `resolve_config/2` adds application config lookup.
Handoff eligibility (`ConversationHandoff.required?/2`) is separate from constructing the
request (`ConversationHandoff.prepare_request/2`). These operations describe state and effects;
only the action return value adopts state and only directives execute effects.


If a directive raises, the runtime stops that effect batch and retains the
already adopted state. Subscribers observe that state, synchronous callers
receive the error, and DurableServer checkpoints the state as usual. Effects
already delivered are not rolled back; later directives in the batch do not run.

Signal emission descriptors may use
`%Aikido.Signal{id: nil, type: "work.ready", data: %{}, source: "/worker"}`.
Emit, Schedule and Cron complete missing envelope IDs and timestamps during
execution. Constructing the directive performs no I/O. Identity, memory and
thread actions use the input signal's timestamp and deterministic state/entry
IDs rather than reading the clock or generating random IDs. Direct calls without
an input signal use timestamp zero. Mounted slice resources apply their native
attribute defaults during initialization.

`CronCancel` queues an ordered runtime request, so it also cancels a registration
returned earlier in the same directive batch. The runtime retires that job's
ownership and saved definition before supervised shutdown. Cancellation completes
with `aikido.agent.cron.cancelled`; subscribe before triggering it when completion
matters. A subsequent replacement keeps its own process and definition even if
shutdown of the previous process finishes later.

Live dynamic cron occurrences inherit the registering signal's native caller
scope and trace context. This implicit context stays in the transient runtime
specification; the saved cron definition retains the original configured message.
Restarting only the scheduler preserves the live context. Reactivating the agent
from durable storage rebuilds the job without that implicit caller context, as do
static DSL schedules. Explicit scope supplied in a configured message remains
application-owned configuration and must be safe to persist.

`SpawnAgent` starts durable child agents and snapshots their current logical parent. Teams add desired topology,
dependencies, ownership, lazy activation, dynamic worker templates, and task
receipts. A team resource can itself be a member or a worker template.

A `partition` scopes logical identities inside a runtime instance; it does not
provide Ash authorization or security isolation. Use Ash actors, tenants, and
policies for application access control.

See [teams](teams.md), [multi-tenancy](multi-tenancy.md),
and the runnable `examples/agent_app` application.

## Native Ash tracing

Pass `tracer: MyApp.Tracer` to a domain action, or configure Ash's `:tracer`
setting. Aikido also accepts a tracer or list of tracers through its
observability configuration. Tracers implement `Ash.Tracer`.

Signal envelopes carry the opaque context returned by
`Ash.ProcessHelpers.get_context_for_transfer/1`. The runtime installs it with
`transfer_context/1` for the current turn and restores the previous context
when the turn finishes, including on failure. Aikido does not generate its own
trace IDs or span IDs.

Native Ash action spans connect to custom signal, directive and asynchronous
work spans. AsyncTask results, AI setup/model/tool results, emitted signals and
delayed signals preserve that ancestry. Retries create individual attempt spans.
Signal IDs and types remain metadata on spans and telemetry events.

The connection lasts across process boundaries even after the initiating call
has returned. Snapshot recovery starts new work; it does not resume an active
span from a terminated process. Custom directives that start their own processes
must transfer Ash context into those processes too, or use `AsyncTask`.

## Lua lifecycle hooks

AI agents and teams accept `hooks` at startup. `Aikido.AI.ask/3` also accepts a
per-request `hooks:` override; `[]` disables configured hooks for that run.
The `ai` DSL section can declare defaults using the same hook maps.

```elixir
hooks = [
  %{
    name: "briefing",
    event: :before_model,
    mode: :sync,
    script: ~s(return {context = "Check the evidence before answering."})
  },
  %{
    name: "observer",
    event: :after_tool,
    mode: :async,
    script: ~s|aikido.send_context("Observed tool: " .. event.name)|
  }
]

MyApp.Agents.assistant_start!(%{model: "zai:glm-4.7", tools: tools, hooks: hooks})
```

Events are `run_started`, `before_model`, `after_model`, `before_tool`,
`after_tool`, `run_completed`, `run_failed`, and `run_cancelled`. Each Lua
`event` table includes `type`, `request_id`, and `iteration`. Run-start events
include `query`; before-tool events include `tool_call` (id, name, arguments);
after-tool events include `tool_call_id`, `name`, and `content`. After-model
events include the normalized `turn`; completion includes `result`.

Hooks are considered in declaration order at an event; asynchronous completion
order is independent. A synchronous hook runs
to completion before the affected step proceeds, but runs in a supervised task
so the agent can still receive cancellation and other signals. It returns nil
or a table with `decision = "continue"`, optionally with a `context` string.
`decision = "deny"` with an optional `message` fails the run before releasing
the held effect. Lua errors and invalid results also fail closed. This does not
undo effects that have already been dispatched. Terminal synchronous hooks
finish before the final completed/failed status is published.

Async hooks do not delay the loop, and their return values are ignored. They
can call `aikido.send_context(text)` or `aikido.send_signal(type, data)`.
Both target the originating agent. Custom signals carry the originating
request ID; application actions should reject stale IDs where relevant.
Internal `ai.react.*` signals cannot be sent through the custom-signal helper.
An async Lua failure is recorded in `ai.hook_errors` (the latest 20 errors)
without failing the run. Hook failures do not recursively invoke failure hooks.

Hook context is queued by an action, then added as a labeled user-role context
message immediately before the next model request. It never changes a request
already in flight or separates a tool call from its results. Context for an old
or finished run is ignored. There is no guarantee an async observer finishes
before the run's last model request; use a synchronous hook when that context
must be present. Gates use request IDs and sequence tokens to ignore stale or
duplicate completions, and cancellation invalidates their continuations.

Each invocation builds a fresh VM through `AshLua.new`, then installs `event`
and the hook helpers. Both modes can request a response; only async hooks receive
the fire-and-forget signal helpers. Hook scripts call Ash actions through the
configured AshLua surface, independently of the model's tool registry. Actions
retain their own authorization. Scripts cannot directly write agent state.
Ash types validate hook configuration and decisions; AshLua owns action bindings
and value encoding.

Select the surface with serializable `lua_options` on each hook:

```elixir
%{
  name: "briefing",
  event: :before_model,
  mode: :sync,
  lua_options: [otp_app: :my_app, labels: [:analysis]],
  script: """
  local stats = assert(analysis.text_stats({input = {text = "Briefing"}}))
  return {context = "Briefing words: " .. stats.words}
  """
}
```

The domain defines `analysis.text_stats` through `AshLua.Domain`. Native `labels`
and `action_entrypoints` filters select the exposed functions. Alternatively,
`lua_options: [eval_resource: MyApp.LuaSurface]` reuses an `AshLua.EvalActions`
resource's configured surface. Empty options expose no Ash actions. Caller actor,
tenant and application context come from the current signal at execution time;
they are not part of the saved VM configuration. A VM is never stored in agent
state.
Defaults are 100,000 VM instructions, a call depth of 64, and 1 MiB per string.
Override these with `max_instructions`, `max_call_depth`, and `max_string_bytes`
on a hook. Hook tasks are ordinary supervised tasks, not durable jobs; saved
run state does not itself resume an interrupted VM or replay an external effect.

Run the example app and open `/examples/hooks` for an offline demonstration,
including the hook context panel, signal timeline, and expandable source code.

### Experimental request / response from Lua

Both sync and async hooks can call `aikido.request(type, payload)`. The Lua task
invokes the hook's application-supplied `request` callback and returns its answer
to the same script. Aikido supplies no request registry or UI transport. Only Lua
decides what the response means:

```lua
local answer, err = aikido.request("tool.review", {
  title = "Run this tool?",
  details = event.tool_call,
  choices = {"approve", "deny"}
})
if err then return {decision = "deny", message = err.message} end
if answer.choice == "approve" then return {decision = "continue"} end
return {decision = "deny", message = "Declined"}
```

Configure the callback at startup or on a per-run hook:

```elixir
%{
  name: "review_tool",
  event: :before_tool,
  script: script,
  request: &MyApp.Interactions.request/2
}
```

The callback receives `%{type: type, payload: payload}` and a context map with
`hook`, `request_id` (the AI run ID), and `event` (the hook's event snapshot).
It returns `{:ok, response}` or `{:error, reason}`. Ash's function type validates
that it is an external capture (`&Module.function/2`) accepting two arguments.
Anonymous closures are rejected so checkpoints cannot retain captured runtime values.
Pass serializable per-run configuration in the ask action's `metadata`; the callback
reads it from `context.event.metadata`. Without a callback, Lua receives
`nil, {message = ":request_callback_not_configured"}`. Errors become the second
Lua return value; callback exceptions fail the hook normally.

The callback runs in the hook task and may wait without blocking the agent
mailbox. The application owns authorization, UI communication, deadlines and
cancellation. Aikido does not wait for a special approval signal, inspect the
agent for pending interactions, or add a response action. External captures are
portable callback references; they do not capture a user or browser session.
Saving a callback reference does not restore a waiting Lua continuation.

The example app supplies a callback when starting `InteractiveAssistant`. Its
existing `Playground` process holds the pending UI card and the callback caller,
then publishes its normal PubSub update. LiveView replies through Playground,
which returns `{:ok, response}` to the callback. That return resumes Lua. The
application removes cards on reply, timeout, caller exit, cancellation or stop;
LiveView reconnection can redisplay cards while Playground and the waiting task
survive. There is no additional Aikido service in the supervision tree.

Open `/examples/hook-requests` to try the complete flow offline. The Lua script
asks only about the `stamp` tool; other tools may run before that gate. The
example callback's deadline is two minutes, and the card also offers cancellation.
Set external caller timeouts long enough for the interaction. Pending requests
and Lua continuations are ephemeral and do not survive process restarts.

### Snapshot and command scope boundaries

DurableServer is the persistence path for agent snapshots, including complete
thread history and runtime cron definitions. Configure its backend with the
runtime's `durable` options. Per-path serialization can implement
`Aikido.Durable.Codec`; it changes the stored representation without introducing
a separate store. A codec must retain enough data for `reinstate/1` to rebuild
the value.

The current snapshot envelope contains the serialized agent, logical parent
binding, cron definitions, restart configuration and selected runtime boot
options. It encodes compressed Erlang terms as a Base64 payload inside a map;
it does not automatically dump all attributes to JSON through Ash types.
Ash types validate action and state contracts; application codecs decide the
persistent representation. Prepared AI tool callbacks and live run scope are
excluded by the ReAct slice codec and tools are rebuilt for each new run.

Both first activation and later durable snapshots apply slice `externalize/1`
and agent `checkpoint/2`; loading applies `restore/2` and `reinstate/1`. Startup
state is not saved a second time in process options. Keep credentials out of
snapshots; persist application identity only through application-owned codecs.
Explicit middleware configuration is retained for restoration;
keep credentials out of that configuration and resolve them through application
providers instead.

Native Ash commands carry the caller's actor, tenant and application context
through initialization, signal processing and follow-up effects. Explicit native
authorization options reach Aikido's nested actions. The pinned Ash AI executor
forwards actor, tenant and context to tool actions; its underlying calls do not
forward per-call authorization or tracer options. Those actions use their own
configured authorization and tracing. A later command supplies its own scope;
startup and command scope are not durable agent identity.
Queued messages and deliveries must match the active run's actor and tenant;
a different scope is rejected with `:scope_mismatch`. Worker queues retain each
task's original scope in memory and discard those queued executions on restoration.

### Conversations and bounded ReAct execution

The ReAct slice retains its conversation between requests. `message(text)`
queues input while a model/tool turn is active. A final answer with queued
messages starts the next turn before completing the request. `deliver(text,
request_id)` starts a run when idle and queues input when busy; teams use this
same interface to wake an orchestrator. `replace_context(messages)` installs
caller-supplied conversation history while idle and refreshes the cached token
estimate, such as after an externally prepared summary. It rejects replacement
during an active or todo-waiting run.

Pass `options` at agent startup, in `ai`, or per `ask`:

```elixir
options %{
  streaming: true,
  model_timeout_ms: 120_000,
  progress_timeout_ms: 60_000,
  tool_timeout_ms: 120_000,
  model_max_retries: 2,
  tool_max_retries: 0,
  context_max_tokens: 16_000,
  handoff_buffer_tokens: 4_000
}
```

Options use the `Aikido.AiReact.Options` typed struct. Hook decisions likewise use
`Aikido.AiReact.Hooks.Decision`; neither requires a resource or create action. Hook
configuration retains its embedded resource so native casting handles an
omitted or nil `:function` request callback correctly.
A per-request options value
replaces the configured options. Retry defaults are zero. Tool retries must be
explicitly enabled and are appropriate only when repeating the tool is safe.
All attempts and backoff share one overall deadline. Cancellation and owner
termination stop active model/tool attempts; streaming cancellation also closes
the ReqLLM stream. A custom client can wrap provider-specific concurrency limits.
Applications still own cancellation and deadlines inside their Lua request callback.

Streaming clients implement `stream_text/3` and return `ReqLLM.StreamResponse`.
The native response builder assembles tool calls, reasoning and usage. Aikido
batches text/thinking updates by bytes or elapsed time (`stream_batch_bytes`,
`stream_batch_ms`). Subscribe to `ai.react.stream` for partial state. The durable
runtime does not synchronously checkpoint each partial stream update; the
completed turn commits canonical history. `usage` contains cumulative numeric
usage for the current run, including its tool/model cycles.

Context handoff is disabled when `context_max_tokens` is nil (or `handoff` is
false). Near `context_max_tokens - handoff_buffer_tokens`, at the next clean
model boundary, the agent asks the model for a handoff document using its full
current context. That request has no tools and does not stream. The document
must preserve the mission, procedure, decisions, completed work, remaining work
and exact next action. Override the instructions with `handoff_prompt`.

On success, an action replaces model context with the existing system messages
and one takeover message containing the document, appends messages queued during
the handoff, and continues the same run with its prepared tools and todo state.
`handoff_count` and `last_handoff` expose the swap. No tool batch is interrupted.
The slice stores its local count in `estimated_tokens` and updates it for each
message appended to model context, including tool results and hook context.
Handoff checks read that cached count instead of rescanning history. Context
replacement (including handoff) and restoration refresh it once; provider counts
from the previous context are cleared. Queued text is counted when folded into
model context, not while it remains in the queue. The threshold uses the larger
of the latest provider input count and the cached estimate; cumulative run usage
is not mistaken for current context size. Choose
a buffer large enough for the instructions and document and smaller than the
context ceiling. Estimates are not provider-enforced limits.

A failed, empty, truncated or oversized handoff fails the run with
`{:context_handoff_failed, reason}` and preserves its original context. There is
no automatic trimming fallback. Cancellation also stops an active handoff.
The public `replace_context` action installs caller-supplied history while idle; automatic
context handoff operates within an active run through its own result actions.

Restoring an interrupted run retains its conversation but marks the run failed
with `:interrupted`. Missing tool replies are closed with interruption results
before another request, preserving valid tool-call pairing. Running provider
calls, Lua VMs and tool side effects are not replayed automatically.

### Optional todos

Mount `slice :todos, Aikido.Todo.Slice` to expose `todo_add`, `todo_activate`,
`todo_complete`, `todo_block` and `todo_remove` on the domain interface. Each
item has a caller-supplied stable ID, text, blocking flag, metadata, status and
completion result. Repeated completion does not replace existing evidence.
`timeout_ms` can block an overdue item. Restored timed items become blocked
with `:interrupted`, since process-local timers cannot establish a new deadline.

Set `options.completion: :todos` to hold the model's final answer in `:waiting`
until all blocking items complete. A blocked item fails the run. `todo_path`
selects the mount (default `:todos`). This gate is optional; ordinary agents
complete on the model's final answer. Application tools decide what evidence
suffices to complete an item. Workflow IDs and database updates remain owned by
the application; Aikido carries arbitrary `metadata` without interpreting it.

Open `/examples/conversation` to try streaming, retained history and todo-gated
completion without a provider key.

### Native Ash AI tool configuration

Pass a list of Ash AI tool names at start or per request:

```elixir
MyApp.Agents.assistant_start!(%{
  model: "zai:glm-5.3",
  tools: [:run_lua, :lua_docs],
  tool_options: [otp_app: :my_app],
  tool_context: %{context: %{shared: %{role: "researcher"}}}
})
```

For native resource/domain agents, `otp_app` defaults to the resource or domain's
application. `tool_options` is passed to `AshAi.build_tools_and_registry/1`;
for example, `actions: [{MyApp.Lua, [:eval, :docs]}]` selects a resource's
exposed actions. Ash AI owns tool schemas, registry construction, authorization
filtering, argument casting and action execution. Aikido uses the returned
registry directly. There is no per-tool Aikido tuple or callback wrapper.
Native tool action errors reach the model unchanged as Ash AI's formatted content;
execution deadlines and crashes are handled by the bounded I/O task.

A run starts in `:setup`. The opening action returns a `PrepareTools` directive,
withheld until `run_started` hooks allow it. Its result signal routes to
`ToolsReady`, which installs the descriptions/registry, enters `:running` and
constructs the first model request. Before-model hooks then gate that request.
Another start or `replace_context` is rejected during setup. Messages and
deliveries from the same actor/tenant queue until the next model request is
released, including messages arriving while a before-model hook waits.
Cancellation stops active startup work; failures settle the run without calling
the model. Late results cannot revive a cancelled or replaced run. Tool
preparation uses the configured `model_timeout_ms` budget.

Subsequent model/tool actions construct descriptors with the prepared descriptions
or registry already attached. Hooks release each model request after adding hook
context and queued messages; only that boundary checks whether a handoff is
needed. Terminal transitions clear tool callbacks and pending handoffs. Streaming
and context-only actions do not perform setup or rewrite returned directives.

Aikido builds descriptions and the callback registry once per ReAct run, before
its first model or tool effect. Later turns and parallel tool calls reuse them;
callbacks still receive the current invocation context. Finishing or cancelling
the run releases the prepared tools. A new run builds from its selected tools
and caller scope again.

The prepared tools live in transient slice state, populated by a preparation
result signal. The slice's persistence callbacks remove them from snapshots;
only tool names and configuration are retained. Restoring an active run keeps
the existing interrupted-run behavior; the next run prepares fresh tools before
executing. Restoration does not replay an in-flight tool automatically.
Configuration intended for persistence must be declarative. Native Ash AI
options that contain application functions are not reconstructable configuration;
applications supplying those must handle them in their serialization callbacks.

Lua's outer execution/docs tools and its inner function surface are separate.
The application can derive `AshLua.Eval.run/2` and `docs/2` `action_entrypoints`
from the same per-agent shared context, as Makewright does. Supply that context
through `tool_context.context.shared` or the caller's Ash context. Aikido
preserves actor, tenant and configured application context when invoking the
native tools; Lua's inner Ash actions still perform their own authorization.

### Model and tool attempt deadlines

`model_timeout_ms` and `tool_timeout_ms` bound each individual attempt. Retrying
creates a fresh deadline after the cancellation-aware backoff. The retry count
bounds the number of attempts. An optional absolute run deadline further caps
all attempts and backoff; without it these options do not impose an overall run limit.
Streaming progress requires nonempty text, thinking, tool-call content or a
multimodal content part. Metadata and empty chunks do not extend the progress
clock. Cancellation interrupts attempts and retry backoff and releases cleanup.

### Application-owned tool preparation and refresh

Set `options.tool_preparation` to `{MyApp.Tools, :prepare}`. This scoped native
Ash generic action accepts `options` (the native Ash AI keyword options) and
`metadata` (the run metadata), and returns native Ash AI keyword options. It runs
in supervised, cancellable setup work before the model. The application can
perform MCP discovery here and return `extra_tools`; Aikido does not discover MCP
servers or invent another tool format. The returned descriptions and callbacks
are transient. The action reference and application configuration can be saved
and evaluated again on the next run after restore.

The public `refresh_tools` command accepts replacement `tools`, replacement
`tool_options`, and a deep-merged `tool_context`. Active model/tool work retains
its current registry until the next model boundary. Setup refreshes supersede
older generations; stale readiness and failures cannot install or fail the new
setup. Refresh during a synchronous hook waits for its gate. Idle refreshes
update configuration for the next run. Incoming refreshes must match the active
run’s actor and tenant, and preparation retains native Ash authorization.

### Todo continuation, verification and incoming work

Todo completion still defaults to waiting for external work. To let an assistant
continue working after an incomplete answer, mount `Aikido.Todo.Slice` and set:

```elixir
options %{
  completion: :todos,
  todo_continuation: :continue,
  max_todo_continuations: 3,
  todo_verifier: {MyApp.Evidence, :verify}
}
```

The verifier is optional. It is a native Ash generic action accepting `answer`,
`todos` (the blocking items), and `metadata`, returning a boolean verdict. It
runs in cancellable supervised work with the caller's scope and application
context. It may inspect external evidence; the reducer only adopts its result.
A true verdict accepts the answer, so the application owns what constitutes
sufficient evidence. False waits or requests another model turn according to
`todo_continuation`. Verifier errors fail the run. External todo changes on a
waiting run go through verification again. Both the continuation budget and the
normal model-iteration limit bound further work. An exhausted continuation
returns `{:todo_continuation_limit, count}`. Blocked todos fail explicitly.

The public `deliver` command can include a typed `todo` alongside `text` and
`request_id`. It adds the item and starts or queues the incoming conversation
text in the same state transition. Duplicate item IDs or a missing todo mount
reject the entire delivery. Workflow IDs belong in application metadata; tool
implementations can update the application's database and use the ordinary todo
commands to record evidence.

Optional `max_consecutive_tool_errors` and `max_repeated_tool_cycles` bounds
stop a run after consecutive failing batches or repeated cycles of one to four
batches. A successful batch resets the error streak. Native Ash AI errors remain
model-visible tool results, with an additional error marker for the guard;
business tool errors are not retried as transport failures. Both guards default
to nil, preserving model recovery and the existing repeated-call warning.

See the example app's [Makewright scenario checklist](../examples/agent_app/MAKEWRIGHT.md)
for isolated browser flows and the tests that cover each integration boundary.

### Nested work budgets and task-scoped workers

A ReAct ask can supply `metadata: %{aikido_deadline_at: deadline}` where `deadline`
is an absolute Unix timestamp in milliseconds. Supervised setup, model and tool
attempts respect the earlier of this deadline and their configured timeout.
Retries and backoff consume the same remaining run budget. Without this metadata,
existing per-attempt timeouts still apply. Reducers carry the deadline without
reading a clock. Tool actions receive the effective deadline in
`input.context.aikido.deadline_at`; applications can propagate it to delegated work.
The research example does so for every nested assignment.

Team `assign_task` accepts `worker_lifecycle: :keep | :stop` (default `:keep`).
`:stop` requests retirement after the team records the terminal result and all
assignments in that worker's owned subtree settle. A subsequent signal rechecks
idleness before planning the stop. Other topology operations finish first. The
member's topology remains paused and can be explicitly activated again; persistence
retention still independently controls saved snapshots. This is not self-termination
from an action or a directive waiting on its own mailbox.

### Synchronization policy

Start an agent with `sync: %{mode: :periodic, interval_ms: 30_000}`. This is the
default: DurableServer periodically saves dirty state. A successful command
acknowledges processing, not a storage commit; a crash can lose changes since the
last checkpoint. Parent-binding lifecycle changes and graceful stop still synchronize; temporary retention still
deletes the saved identity on stop.

`:automatic` enables native DurableServer synchronization after callbacks.
`:explicit` preserves strict adapter-requested sync after persistent state changes;
streaming deltas remain transient until the completed model turn. Both modes still
use the native periodic interval. Explicit here means the adapter returns
`sync: true`; application reducers never call storage themselves.

Children inherit the effective runtime policy. Set `sync` in a child start input,
team member `initial_state`, or SpawnAgent `opts` to override it. Synchronization
settings are saved with boot options and restored with the agent. Concurrent team
topology commands wait in a transient scoped queue and resume after lifecycle
completion; queued continuations are not recovered after a process restart.
