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


Initialization runs the resource's native initialize action. DurableServer restores
saved state through the configured snapshot codecs, then startup lifecycle signals
run through the existing middleware and action pipeline. Persistence remains
DurableServer's responsibility; middleware does not write a second checkpoint.

Explicit domain stops and stop directives process `aikido.agent.lifecycle.stopping`
before returning the final state to DurableServer. Cleanup actions therefore
contribute their state changes to the final permanent snapshot, and cleanup is
not repeated in `terminate/2`. External supervisor shutdowns use a best-effort
`terminate/2` fallback: that callback cannot return changed state for persistence.
Record business completion through a normal action before stopping the process.

Subscriptions remain in AgentServer. They observe adopted state after directive
execution for the current signal; they do not wait for asynchronous work launched
by those directives. Results of that work arrive as later signals and trigger
later observations. No additional middleware hook is needed for subscriptions.

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
execution. Constructing the directive performs no I/O. Memory and
thread actions use the input signal's timestamp and deterministic state/entry
IDs rather than reading the clock or generating random IDs. Direct calls without
an input signal use timestamp zero. Mounted slice resources apply their native
attribute defaults during initialization.

Every agent mounts `Aikido.Cron.Slice` at `:cron`. Its native actions own job
registrations and recovery; the runtime only translates scheduler monitor
messages into signals. Dynamic definitions are persisted through the slice codec,
while PIDs, monitors, implicit scope and retry state are transient.

`Aikido.Cron.Directives.Cancel` queues an ordered signal, so it also cancels a
registration returned earlier in the same directive batch. The slice action retires
that job's ownership and saved definition before supervised shutdown. Cancellation completes
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

`SpawnAgent` starts durable child agents and snapshots their current logical parent.
`Aikido.Ownership.Slice` records parent and child bindings through attachment,
startup, monitor and exit signals. Read these with
`Aikido.Ownership.parent(runtime)`, `orphaned_from(runtime)` and `children(runtime)`.
Its actions apply parent-death policies and reject stale monitor acknowledgements.
AgentServer translates process messages into signals rather than maintaining a
second ownership record. Live bindings and monitor references are transient;
DurableServer saves the logical parent identity separately and resolves its
current process before activation.

Teams add desired topology, dependencies, lazy activation, dynamic worker
templates and task receipts. A team resource can itself be a member or a worker
template. Team's own slice codec clears live member bindings and lifecycle
operations before persistence, regardless of its mount path.

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

Model I/O executes inside `aikido_model_call` and individual `aikido_attempt`
spans. The native ReqLLM/Req request inherits that context; ReqLLM request
telemetry separately reports HTTP status, duration, retries and provider usage.
This does not add a separate Ash span for each internal Req step.

Native tool action spans also retain the caller tracer. For Ash AI callbacks,
Aikido carries it in Ash's native private action context, which continues through
AshLua's eval action to the Ash actions called by the script. Lua instructions
themselves do not produce individual spans. Applications can use the action and
tool/attempt spans to distinguish VM/tool work from provider requests.

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

### Application interactions from Lua

Hooks contain Lua source and serializable settings, never Elixir callbacks.
Application developers expose approved operations through the existing AshLua
application surface; users write Lua that calls those operations. Hook
`lua_options` selects the application's OTP app, labels or action entrypoints.
Native actor, tenant and context reach the action, and its policies apply normally.
Hook executions create their own VM and capability manifest. The agent Lua tool
uses a separate VM and its own selected surface; neither inherits the other's
actions, tools or Lua globals.

For example, the playground exposes an application-owned `approvals.review`
action. Its implementation waits for the current actor's browser response in the
hook task; the agent mailbox remains responsive. Lua interprets the returned
choice and returns its gate decision:

```lua
local answer, err = approvals.review({input = {
  title = "Allow this task?",
  details = event,
  choices = {"approve", "deny"}
}})
if err then return {decision = "deny", message = err.message} end
if answer.choice == "approve" then return {decision = "continue"} end
return {decision = "deny", message = "Declined"}
```

The hook selects `lua_options: [otp_app: :agent_examples, labels: [:approvals]]`.
The application action derives the owner from the native actor rather than a
user-supplied owner ID. The application owns UI transport, timeout and cleanup.
Only Lua source and the serializable surface selection are persisted. A restart
does not resume an interrupted VM or replay a pending approval. Every new task
requests fresh approval. Open `/examples/hook-requests` to try it offline.

### Snapshot and command scope boundaries

DurableServer is the persistence path for agent snapshots, including complete
thread history and runtime cron definitions. Configure its backend with the
runtime's `durable` options. Per-path serialization can implement
`Aikido.Durable.Codec`; it changes the stored representation without introducing
a separate store. A codec must retain enough data for `reinstate/1` to rebuild
the value.

The current snapshot envelope contains the serialized agent, logical parent
binding, cron definitions, restart configuration and selected runtime boot
options. Slices are typed attributes on the agent resource. Native Ash
struct dumping traverses that resource and its nested slices, using the same
compiled attribute contract as native inspection.
Ash's `:term` and `:binary` types encode and decode the outer transport payload;
their native casts also restore older compressed snapshots. Application codecs
can change a path's persistent representation, stored through Ash's term type.
Prepared AI tool callbacks and live run scope are
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
startup and command scope alone are not durable agent identity.
When a durable ScopeAdapter authenticates a non-nil actor, the activation binds
that execution scope in transient runtime state. Correlated team assignments
execute as the receiving worker; results resume the receiving coordinator under
its own bound identity. The sending agent is retained as provenance, not caller
authority. Public commands keep their supplied scope and authorization, and an
AI command with another actor or tenant is rejected with
`Aikido.Agent.Errors.ExecutionIdentityRequiresRestart`. A staged credential change takes effect
only after stopping and restarting the activation; restore authenticates the
saved credential again. The bound runtime scope itself is not checkpointed.
The generated `execution_identity_matches` command compares the native caller's
actor and tenant against that immutable binding and returns only a boolean:
`Domain.worker_execution_identity_matches!(worker, scope: requested_scope)`.
It is authorized like other public commands and returns `false` when unbound.
It reads neither staged identity attributes nor the AI run's caller. A matching
result proves actor and tenant only, not token revision or credential freshness.
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
during an active or todo-waiting run. A successfully accepted
delivery request ID is retained across subsequent runs and checkpoints: repeating
it does not append the text or start another model run. Supply a new ID for new
input. These receipts remain until the saved agent identity is deleted, so their
storage grows with the number of distinct incoming deliveries. Authorization is
checked before duplicate suppression.

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
configuration uses its embedded resource for native casting of Lua source and
serializable settings.
A per-request options value
replaces the configured options. Retry defaults are zero. Tool retries must be
explicitly enabled and are appropriate only when repeating the tool is safe.
When a directive carries an absolute deadline, preflight, attempts and backoff
remain clamped to it. Subscription registration and the initial owner-state read
share one monotonic preflight window based on the attempt timeout. Without an
absolute deadline, each work attempt retains its configured relative timeout;
completing preflight does not create an overall retry deadline. Public subscriptions
without an explicit timeout still use five seconds, and unsubscribe remains
asynchronous. Cancellation and owner termination stop active model/tool attempts;
streaming cancellation also closes
the ReqLLM stream. A custom client can wrap provider-specific concurrency limits.
Applications still own cancellation and deadlines inside actions exposed to Lua.

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

Set `todo_continuation: :nudge_once` to send one reminder naming open blocking
todos when a final answer leaves work unfinished. A later consecutive idle final
answer for the same todo revision fails with
`Aikido.AiReact.Errors.CompletedUnclosed`. Actual tool dispatch after before-tool
gates, newly consumed messages and pending relevant delegated work interrupt that
idle window. Announcing a tool call or having it denied does not reset it.
`max_todo_continuations`, model iteration limits and the original deadline still
bound the run. `:wait` retains manual waiting; `:continue` retains its existing
bounded continuation behavior.

An application can configure `todo_verifier: {VerificationResource, :verify}`.
The native action receives `:answer`, `:todos` and `:metadata`. Existing boolean
results remain supported. For corrective feedback and per-run application data,
declare an optional `:data` argument and return a native embedded result:

```elixir
action :verify, Aikido.AiReact.TodoVerification do
  argument :answer, :term
  argument :todos, {:array, :term}
  argument :metadata, :map
  argument :data, :term
  run MyApp.Verification.CheckEvidence
end

# Inside the application-owned verification implementation:
Aikido.AiReact.TodoVerification.new(%{
  accepted?: false,
  feedback: "Record evidence for the outstanding items before completing.",
  data: %{attempts: 1}
})
```

Only a verdict matching the current run, iteration and todo revision can adopt
feedback or data. New queued evidence is consumed before another answer can be
accepted. Rejected feedback enters the model conversation; opaque `data` is only
passed to the next verifier invocation if its action declares `:data`. Typed
results replace that value, including clearing it with nil; boolean results keep
the prior value. The native sensitive attribute protects data in inspection. Data
is excluded from checkpoints and cleared on new runs and restoration. Application errors retain their
native typed failure path. Relevant self-notifying delegated tasks and pending
activation hold verification and completion until their results arrive.

Verifier action context exposes actual runtime facts under `context.aikido`:
`agent_pid`, `agent_id`, `agent_resource`, `aikido`, `partition` and `request_id`.
These facts override caller-supplied identity metadata. They identify the receiver;
authorization still uses the current native Ash scope and application policies.
The isolated verified-assistant example demonstrates this verifier contract
without requiring a provider key.

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


## Authenticated durable activation

Configure the application's credential boundary on the shared runtime:

```elixir
{Aikido,
 durable: [scope_adapter: MyApp.AgentComposition.CheckpointIdentity]}
```

The adapter implements `Aikido.Durable.ScopeAdapter`. `prepare/3` receives initial
attributes, native Ash caller options, and the SDK identity map (`agent_module`,
`id`, `aikido`, `partition`, `durable_server`, `durable_key`). It returns
`{:ok, sanitized_attributes, opaque_credential}`. Resolve the receiving agent's
own authority, including a child's own identity and grants; do not reuse a parent
actor as the child. Keep application Accounts calls outside the pure agent domain.

DurableServer encodes and claims the fresh bootstrap without running native
initialization. `restore/3` then authenticates the credential against the expected
identity and current permissions, returning `{:ok, native_ash_scope}`. Its saved
value is `{:uninitialized, encoded_attributes}`, `{:agent, agent}`, or the existing
`{:checkpoint, checkpoint}` tuple. Paired path codecs may have encoded the supplied
attributes. A new agent then runs the normal native Initialize action; a saved
agent uses its restored record. Native Configure, lifecycle signals and effects
receive the authenticated scope. An already running `ensure_started` returns its
existing PID without replacing its authority or initializing it again. A stopped
saved identity is detected through DurableServer's native error-preserving read
for every pool, including anonymous pools without a configured agent module. It
does not require fresh attributes or mint a new credential. Irrelevant fresh
attributes are ignored when restoring an existing saved identity. The eventual
claimed row is authoritative. If it disappears before the claim, an existing-only
start rejects instead of resurrecting stale state or writing an empty bootstrap.
The saved logical identity must match the actual claimed supervisor, key and
partition before the adapter is invoked.

When durable startup returns an `Aikido.Durable.ScopeAdapter.Error`, the generated
public `:start` action preserves it inside the native `Ash.Error.Forbidden` error
tree. Its public fields contain a bounded operation and the adapter's atom refusal
reason; opaque non-atom reasons become `:scope_rejected`. The original startup
stack and exception metadata are excluded. Applications can inspect the typed
error instead of parsing its message. Direct `Aikido.Durable` calls retain their
existing error transport; unrelated startup failures and `:noproc` are not
reclassified as authorization refusals.

`checkpoint/3` receives the live agent, previous opaque credential and SDK identity
before path codecs clear transient values. Return `{:ok, current_credential}` only
when its complete binding matches the live identity. To rebind an idle agent,
issue the replacement credential at the authenticated application boundary and
adopt it with the identity in one native reducer result. Keep that attribute
sensitive, exclude it from tools and public inspection, and remove it in the
resource's pure checkpoint or path codec. The envelope retains the opaque
credential separately. A sensitive flag alone is not an inspection access policy.

Fresh supplied paths use their existing `externalize/1` and `reinstate/1` callbacks
without creating records before the claim. Owners can implement `reinstate/2`
to receive `%{fresh?: true}` for sparse startup input and
`%{fresh?: false}` for initialized snapshots. The one-argument callbacks remain
required. Fresh decoding must not apply crash-recovery settlement to never-started
work.

The SDK uses native constrained Ash maps to retain and normalize declared mount
paths and their immediate attributes, including string keys. Whole-agent
checkpoint preparation requirements are checked before encoding any supplied path. It does not recursively reinterpret embedded resources,
NewTypes, maps or callback fields. Nested inputs receive their normal native
casting, defaults and validation during initialization after the durable claim.
Opaque metadata and codec-owned data retain their authored representation.

A path codec or the scope adapter's preparation callback owns safe pre-storage
content, including removal of credentials. A checkpoint-only serializer cannot
sanitize partial startup input without initialization; nonempty supplied paths
for such owners return `{:error, {:bootstrap_preparation_required, owner, path}}` unless
a paired codec or an explicitly prepared adapter input is available. If a codec
fails, or its output cannot round-trip through Ash's safe term type, startup
returns `{:error, {:bootstrap_codec_failed, owner, path}}` without storing a raw
fallback. Declaring an attribute sensitive does not remove it from persistence.

Persisted hook configuration contains only Lua source and serializable settings.
No Elixir function field, function reconstruction or generic callback walker is
part of the hook contract. Application operations are registered in the Lua VM
through the normal AshLua surface, rather than stored as callbacks in state.

Initialized snapshots from the preceding published implementation continue to
restore through native embedded types. An old **uninitialized** envelope containing
retired generic callback-location bookkeeping is rejected explicitly instead of
passing encoded strings to an unrelated owner's codec. Delete that saved identity
and start it again with its owning codec. This reset policy applies to that
unfinished bootstrap format; initialized data still passes through the current native resource schema.

Without an adapter, anonymous scope-free agents retain normal activation. A
scoped durable activation requires an adapter rather than persisting its raw
actor, tenant or application context. Adapter errors must never contain a token,
raw authority or secret input. Test revocation and current policy changes as well
as a successful restart. Local storage must survive for either case to recover.

## Tool runtime diagnostics

Prepared tool execution starts in the directive callback:

```elixir
Aikido.AiReact.Directives.ToolExec.exec(directive, input_signal, state)
```

The callback schedules execution through
`Aikido.AiReact.CancellableTask.run_cancellable_attempts/5`. A generic
runtime failure produces one error-level operator diagnostic with the tool name
and the same reference UUID delivered to the model. The diagnostic contains a
fixed failure kind, a recognized structural code (or `unknown_runtime_failure`),
and the exception module when the captured term is an exception. It does not
print error messages, private causes, arbitrary reason fields, arguments, scope,
context or source paths. This is a payload-free projection, not arbitrary-text
secret detection.

Caught work exceptions and throws/exits currently do not retain their stack in
`CancellableTask`; their diagnostic explicitly reports `stack_unavailable`.
A Task DOWN error that supplies the native `{exception, stacktrace}` shape can
contribute at most four argument-free module/function/arity frames. Names are
bounded; source locations and argument values are omitted. Unrecognized or
malformed shapes never fall back to inspecting their payload. The shape is not
an authenticated provenance contract, and this projection does not alter other
OTP, dependency or application loggers.

`Aikido.AgentServer.cast/2` delivers the existing `ai.react.tool.completed`
envelope with the same reference and opaque recovery guidance. The diagnostic
does not change retries, timeout/cancellation outcomes, native tool errors or
the original internal error term. A reference is not evidence that retrying a
partly completed effect is safe.


## Deterministic attempt timing

Cancellable model I/O uses a per-call timing capability. Production defaults use
System clocks and Process timers. A trusted application or test can supply its
own implementation of `Aikido.AiReact.AttemptTiming` through native call scope:

```elixir
scope = %{
  actor: actor,
  tenant: tenant,
  context: %{aikido_attempt_timing: {MyAttemptClock, private_clock_context}}
}
```

LLMCall forwards that value only into transient CancellableTask execution options.
It is not an AI slice option, provider option, actor replacement or checkpoint
attribute. Do not store timer callbacks or clock processes in durable agent state.
The backend provides monotonic and system milliseconds, schedules a private tag
at an absolute monotonic deadline, cancels superseded timers, and bounds actual
native subscription/state transport through `control_timeout/2`.

A manual test clock must control timer delivery as well as time reads. Attempt,
progress and retry backoff wait on unique private tags. Progress rearms the
progress window without moving the total attempt deadline. Stale canceled tags
cannot expire another wait. Cleanup registration moves neither deadline. The
production control timeout remains the logical remaining budget; a test backend
can use a bounded failure ceiling for actual GenServer control calls while the
separate logical clock remains authoritative for business deadlines.

Drive real provider work and wait for its rearmed timer before advancing virtual
time. Assertion receive timeouts then serve only as failure ceilings. This lets
a stream last longer than one progress window while proving every actual content
gap stays inside that window, without sleeps or fabricated agent state.
