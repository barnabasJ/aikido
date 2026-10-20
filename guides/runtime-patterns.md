# Choosing a Runtime Pattern

Use Ash agent resources (`Aikido.Ash.Agent`) for typed agent state and domain actions.
Add `Aikido.Ash.Team` when an agent manages a named topology of workers or nested
teams. Add `Aikido.Ash.AI` for model turns and dynamically supplied tools.

The default `Aikido` supervision tree uses DurableServer for activation, snapshots,
and recovery. Configure its backend with `durable: [...]`. Use `Aikido.Durable`
for a separately configured DurableServer namespace; it delegates process ownership
and storage to DurableServer.

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
Aikido.Dsl.Instance.Info.instance_options(MyApp.Runtime)
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

Signal emission descriptors may use
`struct!(Jido.Signal, id: nil, type: "work.ready", data: %{}, source: "/worker")`.
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

Each invocation gets a fresh sandboxed VM with `event` and the safe Lua standard
library. Both modes can request a response; only async hooks receive the
fire-and-forget signal helpers.
They cannot access the model's tool registry or write agent state. Ash types
validate hook configuration and decisions; Ash Lua owns value encoding.
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
Explicit middleware and dispatch configuration is retained for restoration;
keep credentials out of that configuration and resolve them through application
providers instead.

Native Ash commands carry the caller's actor, tenant and application context
through signal processing and follow-up effects. They do not turn an outer
action's authorization bypass into a bypass for downstream tools. A later
command supplies its own scope; command scope is not durable agent identity.
Queued messages and deliveries must match the active run's actor and tenant;
a different scope is rejected with `:scope_mismatch`. Worker queues retain each
task's original scope in memory and discard those queued executions on restoration.

### Conversations and bounded ReAct execution

The ReAct slice retains its conversation between requests. `message(text)`
queues input while a model/tool turn is active. A final answer with queued
messages starts the next turn before completing the request. `deliver(text,
request_id)` starts a run when idle and queues input when busy; teams use this
same interface to wake an orchestrator. `handoff(messages)` replaces an idle
conversation with a validated ReqLLM context, such as an externally prepared
summary. It rejects replacement during an active or todo-waiting run.

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

Options use the `Aikido.AI.Options` typed struct. Hook decisions likewise use
`Aikido.Hooks.Decision`; neither requires a resource or create action. Hook
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
The separate public `handoff` action replaces history while idle; automatic
context handoff operates within an active run through its own result actions.

Restoring an interrupted run retains its conversation but marks the run failed
with `:interrupted`. Missing tool replies are closed with interruption results
before another request, preserving valid tool-call pairing. Running provider
calls, Lua VMs and tool side effects are not replayed automatically.

### Optional todos

Mount `slice :todos, Aikido.Slices.Todo` to expose `todo_add`, `todo_activate`,
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

A run starts in `:setup`. Startup hooks and tool preparation must finish before
it enters `:running` and sends its first model request. Another start or handoff
is rejected during setup. Messages and deliveries from the same actor/tenant
are queued and included in that first request. Cancellation stops an active
preparation task; failures settle the run without calling the model. Late results
cannot revive a cancelled or replaced run. Tool preparation uses the configured
`model_timeout_ms` budget.

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
