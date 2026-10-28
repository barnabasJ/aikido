# Ash domains, agents, slices, and teams

Define your public API on an Ash domain. Agents are Ash resources extended by
`Aikido.Agent.Extension`; slices are embedded Ash resources with `Aikido.Slice.Extension`;
teams are agent resources with `Aikido.Team.Extension`.

The project requires Ash 3.37.2 or later in the 3.x series. Configure Ash's required string length
behavior in your application's `config/config.exs`:

```elixir
config :ash, default_string_length_count: :codepoints
```

The existing `Aikido.AgentServer` runs the processes. State changes still come
exclusively from action return values. Agent and slice actions are pure and must
never perform side effects. Return directives for all I/O, including message
delivery, database writes, model requests and process creation; the runtime
executes them after applying the action result.
AgentServer runs the original resource module. Its attributes, actions, slice mounts
and middleware configuration are reused directly; no companion resource is generated.
Own-state fields, AI flags and team configuration live in Spark and are read through
`Aikido.Agent.Info.state_fields/1`, `ai?/1` and `team_config/1`.

A private `:initialize` generic action uses a shared implementation, configured
by the transformer with the state path and slice mounts. Native create actions
apply defaults, validation, authorization and hooks with the caller's scope. The
own-state create action is manual, so it constructs the record without writing
the resource's independent data layer. Mounted embedded slices run their native
create actions. The native
initialization code interface accepts a parameter map, such as
`MyAgent.initialize!(%{id: "example", state: %{count: 1}})`.

Embedded resources also expose an update action for typed attribute changes.
Use `Ash.Changeset.for_create/4` or `for_update/4` to validate proposed inputs
without executing an action. There is no separate whole-agent validation API.
Commands to running agents continue to use the public domain's signal actions.

The convenience form `use Aikido.Agent, domain: MyApp.Agents` accepts native
`Ash.Resource` options, including authorizers, data layers, notifiers and extra
extensions. Aikido adds its agent extension and supplies `Aikido.RuntimeDomain`
only when no domain is specified. Domain inclusion uses Ash's normal validation;
register application agents in their domain. `use Aikido.Slice` likewise forwards
native resource options and defaults to the embedded data layer.

## Source organization

Each distinct action has its own native implementation module, such as
`Aikido.AiReact.Actions.Ask`. Its route binds that module directly. Shared
helpers contain reusable mechanics rather than selecting another action by name.
Signal declarations generate the native Ash actions on the existing resource;
the implementation modules provide their callbacks without creating resources.

Shared lifecycle reducers such as `Aikido.Actions.Lifecycle.StopSelf` live under
`Aikido.Actions.Lifecycle`.

Result contracts live under `Aikido.Types`, including `ActionResult` and `Directive`.

Finite states and modes use feature-owned `Ash.Type.Enum` modules. For example,
`Aikido.AiReact.Types.Status` defines `idle`, `setup`, `running`, `waiting`,
`completed` and `failed`. The same type flows into resource attributes, generated
reducer arguments and native storage casting. Open-ended names and paths remain atoms.

Place each resource beside its owned `actions/`, `signals/` and `directives/` folders.
Their modules use matching `Actions`, `Signals` and `Directives` namespaces;
ordinary shared helpers stay directly under the feature.
For example, `counter.ex`, `counter/actions/increment.ex` and
`counter/signals/add.ex` keep the example counter's state, reducer and payload
contract together, with each filename matching its module.

Library features follow the same rule: ReAct signals, hooks, execution helpers
and directives live under `Aikido.AiReact`; runtime protocol signals live
under `Aikido.AgentServer.Signals`. Each Ash extension owns its `Info`,
`Transformers` and `Verifiers` modules. Shared envelopes, routing infrastructure
and reusable directives remain in their shared subsystems.

## An agent resource

Start an Aikido instance in your application supervision tree:

```elixir
children = [
  Aikido
]
```

Add `Aikido.Agent.Extension` to the resource extensions:

```elixir
defmodule MyApp.Signals.Add do
  use Aikido.Signal

  signal do
    type "counter.add"

    schema do
      attribute :amount, :integer do
        description "Amount to add to the counter."
        allow_nil? false
      end
    end
  end
end

defmodule MyApp.Increment do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.Types.ActionResult.new(changes: %{count: state.count + input.arguments.amount})
  end
end

defmodule MyApp.Counter do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "counter"

    schema do
      attribute :count, :integer do
        description "Current counter value."
        default 0
        public? true
      end
    end

    route MyApp.Signals.Add, MyApp.Increment do
      public? true
    end
  end
end
```

The signal owns the payload contract; the resource owns the state contract.
Aikido generates a native reducer action with those typed arguments and
`run MyApp.Increment`. The implementation uses
`Ash.Resource.Actions.Implementation` and returns `Aikido.Types.ActionResult`.
There is no separate reducer action declaration to keep in sync.

`schema do` uses the same attribute declarations as Ash's `attributes do` block.
The DSL transformer moves those declarations into real resource attributes at
compile time. Initialize with `%{count: 4}` and inspect state explicitly after a
command. Attributes carry Ash types, constraints, defaults, visibility and nil
validation. Mounted slices become additional attributes. Internally the runtime
groups the agent's own fields under `:state`; `path :other_name` changes that path.

Each public command uses its own native implementation under `Aikido.Agent.Commands`.
These implementations live in `lib/aikido/agent/commands/` and perform I/O at the
external domain boundary. Agent/slice `actions/` contain pure reducer implementations.
The transformer attaches each command implementation directly. Shared reference resolution,
snapshot projection and caller-scope helpers live in `lib/aikido/agent/command_runtime.ex`.

The generated public actions are all generic Ash actions: `start`, `stop`,
`delete`, `inspect`, `list`, and the declared signals. These public commands do
not use CRUD actions; internal create/update actions handle typed state
initialization and changes.

Adding `Aikido` to your supervision tree starts `Aikido.Default`. Resources use this
runtime automatically. Set `instance MyApp.AgentRuntime` only when using another
runtime, started with `{Aikido, name: MyApp.AgentRuntime}`.

Agent resources configure snapshot retention in the `agent` block:

```elixir
agent do
  name "scratch_worker"
  persistence :temporary
end
```

The default, `persistence :permanent`, retains saved state when `stop` is called.
Starting the same ID restores that state. `persistence :temporary` deletes the
snapshot on stop, so starting that ID again creates fresh state. Both modes
checkpoint while running and support recovery after an unexpected crash. This
setting controls retention after stop; it is independent of DurableServer's
`permanent` automatic-restart option.

Every resource also exposes `delete`, which stops the process and deletes its
saved state regardless of retention. It accepts a running PID, reference, or ID;
an ID or reference also works after stop, without activating the agent:

```elixir
{:ok, %{status: :stopped}} = MyApp.Agents.counter_stop(counter)
{:ok, %{status: :deleted}} = MyApp.Agents.counter_delete(counter.id)
```

Deletion removes this agent's DurableServer snapshot; externally stored data
owned by tools or application resources has its own lifecycle.

DurableServer handles process activation and configured snapshot persistence.
The agent extension does not occupy the data-layer slot. Resources use Ash's
standard default unless the application selects another data layer. Selecting
AshPostgres or another layer does not automatically persist live agent snapshots
or make process effects transactional; generic actions still use the agent runtime.

The required second argument is the implementation module:
`route MyApp.Signals.Add, MyApp.Increment`. The public command and its
native reducer are generated from the signal's schema. The reducer's state
argument uses the owning resource's schema, including Ash field constraints.
Reducer implementations remain pure; return directives for I/O.

Mounting an embedded slice exposes its routed public signals automatically;
do not repeat them on the agent. Names come from signal definition module names
converted to snake case. Override the command name with `name :custom_name` inside
the route block. Concrete routes are public by default on both agents and slices;
set `public? false` inside the block to keep a route internal.
Wildcard routes remain internal observers. Conflicting inherited names fail
compilation; an explicitly named agent route can override an inherited command name.

Explicit native Ash action references remain available for actions whose
contracts the application owns. Their native argument contracts are preserved,
including whole `data` defaults and nullable/scalar payloads. An explicit public
`action :name, :map` can customize preparations and arguments; omit its `run`
implementation so the transformer installs signal delivery.

Each signal action takes `agent`: a stable string ID, a current PID, or a reference
returned by `start`. The result is a small receipt containing `id`, `pid`,
`resource`, `signal_id` and `status: :processed`. Processing acknowledges the
signal callback. Asynchronous work can still be pending. Team topology lifecycle
actions subscribe once before delivery and wait for their correlated operation.
AI `ask` returns a processing receipt; await its answer through a result subscription,
as demonstrated by `AgentExamples.AI.ask/3`.

Use IDs for durable identity: recovery may replace a PID. Neither a receipt nor
a snapshot establishes exactly-once external effects or a durable input inbox.
Native state transitions return `Aikido.Types.ActionResult`, an `Ash.TypedStruct` with
`changes` and `directives`. Define directives with `use Aikido.Directive`,
Ash's `typed_struct` fields, and an `exec/3` behaviour callback in the same module.
Directive modules are checked with Ash's native `:module` behaviour constraint,
which delegates to Spark. The runtime validates every returned result before applying state
or executing effects, including raw maps returned by native actions. Use
`Aikido.Types.ActionResult.new/1` for validation when calling an action directly with Ash.
Ash owns arguments, defaults, constraints, preparations, authorization, and errors.

Agents can declare the same native reducer actions directly, without slices.
Local reducers are compiled as private Ash actions so their public signal commands
can keep the declared names. Generated domain interfaces expose only public actions;
callers pass an agent reference and payload, while the runtime supplies current state.

`Aikido.AgentServer.call_until/5` registers a one-shot subscription before sending
a command and waits for its selector to return a result. It handles process exit,
timeout and subscription cleanup. Use it from external callers for asynchronous
completion; selectors return `:skip` while waiting. Team lifecycle commands use it.

## Signal matching

Native `Aikido.Signal.new/1` and `new!/1` validate envelopes without generating
IDs or timestamps, so native Ash casting remains pure. At an I/O boundary, use
`Aikido.Signal.materialize/1` to supply missing metadata. The `new(type, data, opts)`
convenience and typed definition constructors also materialize their envelopes.
Directive execution materializes incomplete signals before delivery.

Internal messages use `Aikido.Signal`. Its payload can contain native runtime
values, and its scope and opaque Ash tracer contexts travel with the message.
It is an internal process contract; accepting an external event still requires
the application to authenticate it and establish a trusted scope.

Define reusable typed signals with the same attribute syntax used for state:

```elixir
defmodule MyApp.IncrementRequested do
  use Aikido.Signal

  signal do
    type "counter.add"
    source "/worker"

    schema do
      attribute :amount, :integer do
        description "Amount to add when handling this signal."
        allow_nil? false
        default 1
      end
    end
  end
end

{:ok, signal} = MyApp.IncrementRequested.new(%{amount: 2})
```

Signal definitions are native Ash payload types. `Ash.Type.cast_input/3` casts
the payload using its declared fields, constraints and defaults. The definition's
`new/1` and `new!/1` constructors wrap that payload in an `Aikido.Signal` and
generate runtime metadata, so call them at I/O boundaries.

Routes generate native reducer actions from their implementation modules:

```elixir
route MyApp.Signals.Add, MyApp.Increment
route [MyApp.Signals.Add, MyApp.Signals.Reset], MyApp.CounterEvents
route "**", MyApp.CountSignals
```

A single definition supplies flat payload arguments, such as `amount`. A list
supplies `input.arguments.data` as a native `Ash.Union`, with variants named from
the signal modules (`:add` and `:reset` here). The matched event type selects the
variant before native casting, so overlapping payload schemas are unambiguous.
The implementation can pattern-match `%Ash.Union{type: :add, value: payload}`.
A wildcard route supplies generic `data` as `:term`; this supports observers that
count every signal without assuming a payload schema. All three forms receive
state typed from their owning resource. Slice state retains its resource struct.

Pure reducers construct signal descriptors without generating IDs or timestamps:

```elixir
%Aikido.Signal{type: "counter.add", data: %{amount: 1}, source: "/worker"}
```

Return an `Aikido.Directives.Emit` descriptor to deliver it directly to an agent
process. At execution, the directive supplies missing runtime metadata and
inherits the triggering signal's scope and tracing context. Subscriptions send
ordinary process messages to their registered recipient PID.

Broadcasts use `Ash.Notifier.Notification` through a notification directive,
after the reducer's returned attribute changes have been applied. Application notifiers can
publish to Phoenix PubSub or another destination. When the notification omits
its resource, the directive supplies the originating agent resource for native
notifier metadata. Explicit resources and notifier selections are preserved.
Do not return native Ash
notifications from a reducer: Ash would dispatch them before AgentServer adopts
the returned changes. Applied state does not imply a disk checkpoint has completed.

`Aikido.Signal.Router` matches the complete signal type against declared paths.
`*` consumes one dot-separated segment; `**` consumes zero or more segments,
including in the middle of a path. An exact `counter.add` route does not match
`counter.add.extra`.

All matching declarations contribute actions. Exact paths precede paths with
`*`, which precede paths with `**`. Within a class, positional specificity,
priority, and declaration order determine execution order. Predicates receive
the original signal and match only when they return `true`; a predicate that
raises, throws or exits does not match. Router construction does not call them.
Subscriptions compile their patterns when registered and observe state after
signal processing.

The routing core is adapted from Jido Signal v3 under Apache-2.0; see `NOTICE`
for attribution. It uses a direct exact-path index and a wildcard trie. Local
benchmarks show gains for small exact-heavy agent tables, but regressions for
some wildcard-heavy tables; these are matching measurements, not end-to-end
agent throughput guarantees. Signal delivery remains handled by directives.

## The domain is the interface

```elixir
defmodule MyApp.Agents do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :counter, MyApp.Counter
  end
end
```

Include the domain in your application's usual `:ash_domains` configuration.
You can also declare ordinary Ash resources in the domain's `resources` block.
Each registered agent's actions get domain interfaces named `<name>_<action>`:

```elixir
{:ok, counter} = MyApp.Agents.counter_start(%{id: "counter-1", count: 4})
{:ok, receipt} = MyApp.Agents.counter_add(counter.id, %{amount: 3})
{:ok, %{count: 7}} = MyApp.Agents.counter_inspect(receipt, %{fields: [:count]})
{:ok, counters} = MyApp.Agents.counter_list(%{filter: [count: 7], sort: [id: :asc]})
{:ok, %{status: :stopped}} = MyApp.Agents.counter_stop(counter.id)
```

Ash generates bang interfaces too. Normal actor, authorization, context and tenant
options apply at the action boundary. `inspect` returns the resource snapshot,
or a map restricted to `fields`. `list` explicitly enumerates live snapshots and
accepts `filter`, `sort`, `offset` and `limit`. Snapshots are taken independently;
they do not provide a transaction across processes. Native Ash defaults apply to
arguments, including defaulted values passed as nil.

The public command runs in the caller's process and sends a signal to the agent.
The reducer runs as a separate native Ash action inside AgentServer. Each is an
Ash authorization boundary when configured with authorizers and policies. Caller
scope, including explicit authorization options and application context, propagates
through startup, signals and directives. Startup scope remains transient and is
not stored in the durable identity. Each configured initialization/create policy
must permit the caller as well as the public start action.

Explicit stop commands likewise forward the current caller's scope to the stopping
lifecycle. Cleanup runs through normal reducers, native updates and directives;
if it fails, the stop command returns the error and leaves the process alive.
A reducer's Stop directive uses that signal's current scope for cleanup. The stop
is still honored if cleanup fails, and synchronous callers receive that error.
Callerless supervisor shutdown has no earlier actor to reuse: cleanup is best
effort under the application's policies, and failures are logged. None of these
paths stores caller authority for future shutdowns.

The pinned Ash AI tool executor forwards actor, tenant and application context to
its underlying Ash actions, but does not forward per-call `tracer` or `authorize?`
options. Those tool actions retain their configured authorization. Native runtime
filter loading receives actor and tenant but likewise does not forward arbitrary
context or per-call tracers internally. Aikido uses these native implementations
rather than replacing their action or filtering engines.
Use normal Ash `tracer:` options to follow the chain across processes; see
[native Ash tracing](runtime-patterns.md#native-ash-tracing).

## Embedded slice resources

Slice `config_schema` fields use Ash types and constraints. Defaults apply when a
field is absent from the merged application configuration and mount options.
An explicitly supplied `nil` stays nil and must satisfy the field's `allow_nil?`
constraint; `false` remains a supplied boolean. Atom keys take precedence over
string keys when both are present.

Slices package state and the Ash actions that operate on it:

```elixir
defmodule MyApp.CounterSlice do
  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Slice.Extension]

  slice do
    name "counter_slice"
    schema do
      attribute :count, :integer do
        description "Current counter value."
        default 0
        public? true
      end
    end
    route MyApp.Signals.Add, MyApp.Increment do
      public? true
    end
  end
end

defmodule MyApp.ComposedAgent do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "composed"

    slice :counter, MyApp.CounterSlice
  end
end
```

Register `agent :composed, MyApp.ComposedAgent` in the domain. Then:

```elixir
{:ok, agent} = MyApp.Agents.composed_start(%{})
{:ok, agent} = MyApp.Agents.composed_add(agent, %{amount: 2})
agent = MyApp.Agents.composed_inspect!(agent)
agent.counter.count # => 2
```

Slice implementations receive their current typed slice value as `state`.
Single-signal fields such as `amount` are cast from the payload and exposed in
`input.arguments`. List routes receive a native union in `data`; wildcard routes
receive raw `data`.
They return `Aikido.Types.ActionResult.new(changes: attributes, directives: directives)`;
`directives` defaults to `[]`. The agent pipeline applies the returned attribute changes
and executes the directives. Runtime action context is available under `input.context.aikido`.
Keep these action implementations pure.

Resource slices support a `schedules` section. Schedules reference generic Ash
action names and send their configured data through the same action adapter:

```elixir
schedules do
  schedule "*/5 * * * *", :add, data: %{amount: 1}
end
```

Slice schedules receive an identity containing the mount path and the normalized
`{target, cron, timezone, signal_type, data}` declaration. Distinct declarations
can schedule the same reducer independently; shared generated routes invoke the
reducer once for each occurrence. Agent schedules keep their explicit `job_id`
(or signal type by default); duplicate expanded IDs are rejected at compile time.
Use distinct `job_id` options for multiple agent schedules sharing a signal.

Declare ordered middleware with `middleware [MyApp.Audit]` inside the agent
section; it wraps signals using the existing Aikido middleware contract.

Mounted slices retain their own Ash attributes and actions. They do not start
processes or generate companion modules. Mounting the same slice resource at
several paths runs its actions against each mount's own state.

## Teams

A team is an agent resource that lists its member resources:

```elixir
defmodule MyApp.ReviewTeam do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "review_team"
  end

  team do
    member :planner, MyApp.Counter, initial_state: %{count: 1}
    member :reviewer, MyApp.ComposedAgent
  end
end
```

Register `agent :review_team, MyApp.ReviewTeam` in the domain. Start launches the
team and waits for its members to register as children. Members have IDs scoped
as `<team-id>/<member-name>` and must share the team's Aikido instance. The `team`
slice tracks live member PIDs through routed child lifecycle actions.

```elixir
{:ok, team} = MyApp.Agents.review_team_start(%{id: "review-1"})

{:ok, team} = MyApp.Agents.review_team_send(team, %{
  member: :planner, type: "counter.add", payload: %{amount: 2}
})

{:ok, %{status: :stopped}} = MyApp.Agents.review_team_stop(team)
```

Pass `topology` to start a caller-defined graph immediately:

```elixir
MyApp.Agents.review_team_start!(%{
  id: "custom-review",
  topology: %{
    "planner" => %{resource: MyApp.Counter, initial_state: %{count: 4}},
    "reviewer" => %{resource: MyApp.ComposedAgent, depends_on: ["planner"]}
  }
})
```

The supplied graph replaces the DSL graph. Omitted or nil uses the DSL defaults;
`%{}` explicitly starts an empty team. Ownership, activation, dependencies and
member state use the same topology format as `configure_topology`. Nested teams
accept their own graph under the node's `initial_state: %{topology: child_graph}`.
Start returns after the initial activation operation completes, including nested
teams; lazy members remain inactive unless required by an eager member.

A restored durable identity retains its saved topology, even if startup arguments
contain a different graph. Use `configure_topology` to change an existing team's
graph explicitly. Root graph structure is validated before activation. Startup
failures request a stop through the normal lifecycle with the current caller's
scope. If cleanup also fails, a native `Aikido.Agent.Errors.StartupCleanupFailed`
error retains the root ID and both failures. The caller can inspect the live root
and retry cleanup with appropriate authority.

`send` emits an asynchronous signal to a member. Use signal subscriptions to
observe its result. Members can return the existing emit/notify-parent directives
to communicate through the signal pipeline. Stopping the team stops its children
through the normal parent-death lifecycle. Process side effects cannot be rolled
back as a database transaction.

## Native contracts and tools

Generated actions use native Ash arguments and return types. Reducers return
`Aikido.Types.ActionResult`; ordinary tools return their declared Ash type. Implement
callbacks with `Ash.Resource.Actions.Implementation` modules and reference them
with a descriptive binding such as `run MyApp.AppendEntry` on the owning resource.

Agent and slice `schema do` declarations become attributes on their existing
Ash resources. Slice configuration declarations remain Spark entities. Resolution
merges application configuration and mount overrides, applies declared defaults,
and casts a constrained map directly with `Ash.Type`. Only declared fields are
returned when a config schema exists; no config action or schema module is
generated. Native Ash constructors and changesets handle state defaults, casting,
and validation;
Ash/Splode errors retain their field paths and nested causes.

AI tool callbacks receive the process-backed resource in trusted
`agent_resource` context. Team members also carry `parent.meta.team_resource`
alongside their team ID. Native Ash AI callbacks receive that runtime context
under `context.aikido`, allowing AshLua actions to find the calling agent's managing
team without accepting team IDs or modules as model inputs. The example app's
`agents` Lua namespace uses ordinary team lifecycle actions to spawn agents or
teams, delegate work, list templates, and stop or remove owned subtrees.

Supply Ash AI tool names in `tools` and native source configuration in
`tool_options`, such as `otp_app` or `actions`. Aikido calls
`AshAi.build_tools_and_registry/1` once per run and reuses its descriptions
and registry across turns and tool calls;
there is no custom per-tool tuple, module shorthand or callback wrapper.
Arguments follow Ash AI's `%{"input" => %{...}}` shape. Actor, tenant and
application context reach the native Ash actions. Snapshots retain declarative
tool configuration rather than generated execution functions. Native validation
remains authoritative for constraints not represented in JSON Schema.

Team lifecycle actions subscribe once before starting their operation and return
a compact receipt after completion. Inspect explicitly when the caller needs the
updated topology. `configure_topology` changes a running team's desired graph;
`start` launches an agent or team using the same interface. Signals and directives
perform the asynchronous work inside the team.

### Sparse reducer changes

Reducers can return only the attributes they change:

```elixir
Aikido.Types.ActionResult.new(
  changes: %{count: state.count + input.arguments.amount},
  directives: []
)
```

The changes apply only to the reducer's own mounted path. Omitted keys retain
existing values. Explicit nil is passed to Ash and rejected when the resource
attribute disallows it. The generated input map filters unknown keys using native
Ash map constraints; the real private update action casts and validates values.
Embedded edits use attribute maps and follow native Ash embedded identity,
update and replacement rules. Existing embedded structs retain native Ash's
trusted-value behavior. Mounted slices remain mounted. Omitting `changes` or
returning `changes: nil` leaves state unchanged and still executes returned directives.

`changes: %{}` also requests no state change. The result contains attribute
changes rather than a complete replacement state; unchanged attributes do not
need to be copied into the result.

The private update retains the reducer's scope and runs native update validations
and policies. Applications with action-specific policies must account for
`:__aikido_apply_state__`. It returns the updated in-memory resource without
writing a separate data layer; DurableServer remains responsible for persistence.

Native Ash notification collection spans the complete routed signal operation,
including embedded updates. If a later reducer fails, staged state and collected
notifications are discarded. On success, the runtime adopts the validated state
before executing notification directives. Explicit reducer directives retain
their declared order. A signal with no changes does not produce an update
notification merely because it was received.

### Native agent publications

Aikido owns publication and subscription declarations and builds the underlying
native Ash PubSub configuration. A resource opts into payload data with a native
`:notification_data` calculation. Slices use the same convention. Without that
calculation, a slice contributes nothing; attributes are never exported by default.

```elixir
calculations do
  calculate :notification_data, :integer, expr(count)
end

notifications do
  pubsub Phoenix.PubSub
  pubsub_name MyApp.PubSub

  publish :changed do
    topic ["counters", :id]
  end
end
```

The generated aggregate calculation composes root data under the agent's own
state path and slice data under each mount name. Two mounts of the same slice
remain distinct. Calculation types, constraints and nullability define the
payload contract. Calculations must declare explicit types and require no runtime
arguments. Native Ash loads the root and nested calculations with the update's
scope. Aikido generates `Publisher.Signals.Changed`; applications do not repeat
its payload schema.

A receiving agent declares the publication, maps publisher topic fields to its
own attributes, and supplies an application-owned scope resolver:

```elixir
notifications do
  scope {MyApp.AgentAuthority, :resolve, []}

  subscribe MyApp.Publisher, :changed do
    bindings id: :publisher_id
  end
end
```

The scope MFA receives the current immutable receiving agent before its configured
arguments and returns `{:ok, scope_map}` or `{:error, reason}`. Resolve authority
from trusted application data. Publisher actor, tenant and context are never
inherited by the receiving signal. Joining a topic does not evaluate a read policy
for every listener. Applications must authorize topic access or publish minimal
invalidation data followed by an authorized read.

Use the generated signal in an ordinary route. When its payload contains `:state`
(the default root path), use an explicit native action accepting typed `:data`,
or the existing signal-list route contract, to preserve the receiver's separate
`:state` argument. A custom root path such as `:metrics` avoids this reserved-name
collision. Publication metadata references are checked after compilation; mutually
referencing generated signal routes still have ordinary compile dependencies.

The built-in notification slice records resolved registrations. Subscription I/O
runs in the receiving process during startup; failures prevent readiness. Graceful
stop unsubscribes, and Phoenix PubSub removes memberships when the process exits.
Checkpoint callbacks clear registrations so restore rebuilds them. Multiple events
on one transport/topic share one actual subscription. Binding attributes must stay
fixed for an activation: changed bindings reject old-topic deliveries until restart.

PubSub is best effort, provides no durable replay, and asynchronous publication
tasks may complete out of order. It does not acknowledge a DurableServer commit or
a separate application SQL transaction. Use revisions and reconciliation when the
application requires stronger ordering or recovery.

The playground's **Native notifications** example demonstrates a counter publishing
its calculation to a child observer. The observer adopts the typed value and sends
an acknowledgement through a normal agent signal. The example's counter is public;
its receiving scope does not claim to implement a private-data authorization policy.
