# Ash domains, agents, slices, and teams

<!-- covers: aikido.integrations_and_migration.framework_guides -->

Define your public API on an Ash domain. Agents are Ash resources extended by
`Aikido.Ash.Agent`; slices are embedded Ash resources with `Aikido.Ash.Slice`;
teams are agent resources with `Aikido.Ash.Team`.

The project uses Ash 3.36 or later. Configure Ash's required string length
behavior in your application's `config/config.exs`:

```elixir
config :ash, default_string_length_count: :codepoints
```

The existing `Aikido.AgentServer` runs the processes. State changes still come
exclusively from action return values, and directives perform runtime effects.
The resource DSL generates the internal agent modules; consumers call the domain.

## An agent resource

Start a Aikido instance in your application supervision tree:

```elixir
children = [
  Aikido
]
```

Add `Aikido.Ash.Agent` to the resource extensions:

```elixir
defmodule MyApp.Counter do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [Aikido.Ash.Agent]

  agent do
    name "counter"
    schema do
      attribute :count, :integer, default: 0, public?: true
    end

    signal :add, "counter.add", :increment
  end

  actions do
    action :increment, Aikido.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :amount, :integer, allow_nil?: false

      run fn input, _context ->
        Aikido.ActionResult.new(state: %{count: input.arguments.state.count + input.arguments.amount})
      end
    end
  end
end
```

`schema do` uses the same attribute declarations as Ash's `attributes do` block.
The DSL transformer moves those declarations into real resource attributes at
compile time. Initialize with `%{count: 4}` and inspect state explicitly after a
command. Attributes carry Ash types, constraints, defaults, visibility and nil
validation. Mounted slices become additional attributes. Internally the runtime
groups the agent's own fields under `:state`; `path :other_name` changes that path.

The generated public actions are all generic Ash actions: `start`, `stop`,
`inspect`, `list`, and the declared signals. No CRUD actions are generated.

Adding `Aikido` to your supervision tree starts `Aikido.Default`. Resources use this
runtime automatically. Set `instance MyApp.AgentRuntime` only when using another
runtime, started with `{Aikido, name: MyApp.AgentRuntime}`.

DurableServer handles process activation and configured snapshot persistence.
The agent extension does not occupy the data-layer slot. Resources use Ash's
standard default unless the application selects another data layer. Selecting
AshPostgres or another layer does not automatically persist live agent snapshots
or make process effects transactional; generic actions still use the agent runtime.

The target is the third positional argument: `signal :add, "counter.add", :increment`.
A local action name targets a native action on the agent; `{MyApp.Actions, :increment}`
targets a reusable action on another Ash resource.
It is required on every declaration. Mounting an embedded Ash slice automatically
exposes its routed public actions with their existing targets and argument contracts;
do not repeat those signals on the agent. Names come from the slice action names.
Private actions (`public? false`) and schedule-only actions remain internal.
Public routes require concrete signal types. Conflicting inherited names fail
compilation; an explicit agent signal can override an inherited action name.

A `signal` declaration generates a generic action with arguments inferred from
its native Ash target or mounted slice route. Types, constraints and defaults
are preserved. Untyped routes accept a `data` map defaulting to `%{}`. An explicit
`action :name, :map` may customize arguments and native preparations; omit its
`run` implementation so the transformer installs signal delivery.

Each signal action takes `agent`: a stable string ID, a current PID, or a reference
returned by `start`. The result is a small receipt containing `id`, `pid`,
`resource`, `signal_id` and `status: :processed`. Processing acknowledges the
signal callback. Asynchronous work can still be pending. Team topology lifecycle
actions subscribe once before delivery and wait for their correlated operation.
AI `ask` returns a processing receipt; await its answer through a result subscription,
as demonstrated by `AgentExamples.AI.ask/3`.

Use IDs for durable identity: recovery may replace a PID. Neither a receipt nor
a snapshot establishes exactly-once external effects or a durable input inbox.
Native state transitions return `Aikido.ActionResult`, an `Ash.TypedStruct` with
`state` and `directives`. Its directives must have a concrete
`Aikido.AgentServer.DirectiveExec` protocol implementation; the `Any` fallback
is rejected. The runtime validates every returned result before applying state
or executing effects, including raw maps returned by native actions. Use
`Aikido.ActionResult.new/1` for validation when calling an action directly with Ash.
Ash owns arguments, defaults, constraints, preparations, authorization, and errors.

Agents can declare the same native reducer actions directly, without slices.
Local reducers are compiled as private Ash actions so their public signal commands
can keep the declared names. Generated domain interfaces expose only public actions;
callers pass an agent reference and payload, while the runtime supplies current state.

`Aikido.AgentServer.call_until/5` registers a one-shot subscription before sending
a command and waits for its selector to return a result. It handles process exit,
timeout and subscription cleanup. Use it from external callers for asynchronous
completion; selectors return `:skip` while waiting. Team lifecycle commands use it.

## The domain is the interface

```elixir
defmodule MyApp.Agents do
  use Ash.Domain, extensions: [Aikido.Ash.Domain]

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

## Embedded slice resources

Slices package state and the Ash actions that operate on it:

```elixir
defmodule MyApp.CounterSlice do
  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Ash.Slice]

  attributes do
    attribute :count, :integer, public?: true, default: 0
  end

  actions do
    action :increment, :map do
      argument :state, :map, allow_nil?: false
      argument :data, :map, allow_nil?: false

      run fn input, _context ->
        {:ok, %{
          state: %{count: input.arguments.state.count + input.arguments.data.amount},
          directives: []
        }}
      end
    end
  end

  slice do
    name "counter_slice"
    schema do
      attribute :count, :integer, default: 0
    end
    route "counter.increment", :increment
  end
end

defmodule MyApp.ComposedAgent do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [Aikido.Ash.Agent]

  agent do
    name "composed"

    slice :counter, MyApp.CounterSlice
  end
end
```

Register `agent :composed, MyApp.ComposedAgent` in the domain. Then:

```elixir
{:ok, agent} = MyApp.Agents.composed_start(%{})
{:ok, agent} = MyApp.Agents.composed_increment(agent, %{data: %{amount: 2}})
agent = MyApp.Agents.composed_inspect!(agent)
agent.counter.count # => 2
```

Slice actions receive their current slice map as `state` and the signal payload
as `data`. They return `%{state: new_slice_map, directives: list}`; `directives`
may be omitted. The agent pipeline applies the returned state and executes the
directives. Runtime action context is available under `input.context.aikido`.
Keep these action implementations pure.

Resource slices also support `subscriptions` and `schedules` sections. Sensor
subscriptions use the existing Aikido sensor modules. Schedules reference generic
Ash action names and send their configured data through the same action adapter:

```elixir
subscriptions do
  subscription Aikido.Sensors.Heartbeat, %{interval: 60_000}
end

schedules do
  schedule "*/5 * * * *", :increment, data: %{amount: 1}
end
```

Declare ordered middleware with `middleware [MyApp.Audit]` inside the agent
section; it wraps signals using the existing Aikido middleware contract.

Existing `Aikido.Slice` modules can also be mounted during migration. Each resource
slice gets an internal Aikido slice and action adapters; it does not start a process
of its own. Mounting the same resource at several paths retains the existing
slice fan-out behavior.

## Teams

A team is an agent resource that lists its member resources:

```elixir
defmodule MyApp.ReviewTeam do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.Team]

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
  data: %{member: :planner, type: "counter.add", payload: %{amount: 2}}
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
graph explicitly. Root graph structure is validated before activation; startup
failures stop the new team through the normal lifecycle.

`send` emits an asynchronous signal to a member. Use signal subscriptions to
observe its result. Members can return the existing emit/notify-parent directives
to communicate through the signal pipeline. Stopping the team stops its children
through the normal parent-death lifecycle. Startup failures stop the new team;
process side effects cannot be rolled back as a database transaction.

## Migration

Existing `Aikido.Agent`, `Aikido.Slice`, plugins, middleware, directives, and runtime
APIs continue to work. Move a consumer to resource declarations and domain
interfaces, then convert its slices to embedded resources. Internal generated
`Runtime` and `AikidoSlice` modules are implementation details.

The separate `ash_aikido` package serves the opposite integration direction: it
exposes existing Ash resource actions as Aikido actions. It is not needed for the
process-backed resource model described here.

## Native contracts and tools

Actions, slice schemas, and sensor configuration also use `schema do` with Ash
`attribute` declarations. Action output contracts use `output_schema do`, and
slice configuration uses `config_schema do`. No separate input module is needed.
Action inputs become native typed structs directly on the action module through
Spark's transformer evaluation hook. Other plain contracts use a nested
Ash.TypedStruct. Native constructors handle literal defaults, casting, and validation. Ash agents
and slices reuse their existing resource attributes and native changesets,
including resource function/MFA defaults. Ash/Splode errors retain their field
paths and nested causes.

AI tool callbacks receive the process-backed resource in trusted
`agent_resource` context. Team members also carry `parent.meta.team_resource`
alongside their team ID. Native Ash AI callbacks receive that runtime context
under `context.aikido`, allowing AshLua actions to find the calling agent's managing
team without accepting team IDs or modules as model inputs. The example app's
`agents` Lua namespace uses ordinary team lifecycle actions to spawn agents or
teams, delegate work, list templates, and stop or remove owned subtrees.

Use `AshAi.build_tools_and_registry/1` to supply Ash tools and their callbacks.
Resource/action pairs also use AshAI for schema generation and execution; their
arguments follow AshAI's `%{"input" => %{...}}` shape. Actor, tenant, and context
are passed through to AshAI. Native validation remains authoritative for type
constraints that AshAI does not currently expose in JSON Schema.

Team lifecycle actions subscribe once before starting their operation and return
a compact receipt after completion. Inspect explicitly when the caller needs the
updated topology. `configure_topology` changes a running team's desired graph;
`start` launches an agent or team using the same interface. Signals and directives
perform the asynchronous work inside the team.
