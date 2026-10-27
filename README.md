# Aikido

Thank you to the [Jido project](https://github.com/agentjido/jido) and its
contributors. Aikido started as a fork of Jido and gradually evolved into an
independent project. Their work provided the foundation for what Aikido is today.

An opt-in [experimental Jido v3 adapter](experimental/jido_ash/README.md) generates
Ash interfaces for named Jido inputs while Jido owns runtime execution and state.
It has a separate dependency graph and does not change the Aikido runtime.

[![CI](https://github.com/barnabasJ/aikido/actions/workflows/ci.yml/badge.svg)](https://github.com/barnabasJ/aikido/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Aikido builds agent systems with Ash resources, typed actions, signals, and an OTP
runtime. Agents and teams share a generic Ash action interface; AI agents use
ReqLLM with dynamically supplied tools. DurableServer provides keyed activation,
snapshots, and recovery.

## Installation

Aikido requires Elixir 1.19 and OTP 28 or later.

```elixir
{:aikido, git: "git@github.com:barnabasJ/aikido.git", branch: "main"}
```

Start the default runtime in your supervision tree:

```elixir
children = [Aikido]
```

This starts shared task, non-agent process, and DurableServer supervision once.
All agents in the runtime use DurableServer's shared dynamic supervisor;
starting an agent does not create another runtime supervision tree. `Aikido`
sets up that runtime; domain actions are the public API for agent lifecycle
and state access.

If you need a separate named runtime, define its module yourself:

```elixir
defmodule MyApp.Aikido do
  use Aikido, otp_app: :my_app
end

# In your supervision tree:
children = [MyApp.Aikido]
```

Set `instance MyApp.Aikido` in the agent block for agents using that runtime.

## An agent and its public interface

Define the payload once as a typed signal and pass its implementation module.
Aikido generates the native Ash reducer and public command:

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
    Aikido.Types.ActionResult.new(state: %{state | count: state.count + input.arguments.amount})
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
        allow_nil? false
        default 0
        public? true
      end
    end

    route MyApp.Signals.Add, MyApp.Increment do
      public? true
    end
  end
end

defmodule MyApp.Agents do
  use Ash.Domain, otp_app: :my_app, extensions: [Aikido.Domain.Extension]

  agents do
    agent :counter, MyApp.Counter
  end
end
```

The generated reducer's `state` argument uses the owning resource's schema.
Payload arguments use the signal's Ash types, constraints and defaults. A route
can also take several signal definitions: its implementation receives a native
`Ash.Union` in `input.arguments.data`. Wildcard observers such as
`route "**", MyApp.CountSignals` receive generic `data` and typed state.

Register the domain in your application configuration:

```elixir
config :my_app, ash_domains: [MyApp.Agents]
config :ash, default_string_length_count: :codepoints
```

Use the generated `<agent>_<action>` domain functions:

```elixir
counter = MyApp.Agents.counter_start!(%{count: 0})
receipt = MyApp.Agents.counter_add!(counter.id, %{amount: 3})
MyApp.Agents.counter_inspect!(receipt, %{fields: [:count]})
# %{count: 3}
MyApp.Agents.counter_stop!(counter.id)
```

Start returns a reference containing the stable ID, current PID, and resource.
Signal actions accept a reference, ID, or PID and return processing receipts.
Inspect state explicitly; asynchronous effects and AI answers complete through
signals and subscriptions. Mounted embedded Ash slices contribute their routed
public actions automatically. Mount each slice explicitly in `agent do`;
`use Aikido.Agent` and `use Aikido.Slice` are conveniences for these same Ash
resource extensions.

## Teams, AI, and persistence

Add `Aikido.Team.Extension` for fixed members, dynamic workers, ownership, dependencies,
and nested teams. A team can accept its initial `topology` in the start call.
Add `Aikido.AI.Extension` for model turns; pass the model, tools, and optional prompt and
iteration settings at runtime. AshAI and AshLua tools can expose management and
delegation capabilities to AI agents. Supply Ash AI tool names in `tools` and
native builder options in `tool_options`. Each request enters `:setup`, prepares
tools once, then runs model/tool turns through actions, directives and result
signals. Messages can queue during setup; cancellation stops pending work.

The default runtime uses DurableServer. Configure a persistent data directory or
backend for the deployment. Snapshot recovery preserves logical agent state and
team topology; it rebuilds runtime membership and monitors. IDs remain stable
when PIDs change. Agent and slice serialization callbacks control snapshot
content. The default local EKV backend stores data under `_build/aikido_durable`;
use a stable directory for deployment, for example
`{Aikido, durable: [data_dir: "priv/agent-state"]}`. Local storage requires the
same disk to remain available.

With `persistence :permanent` (the default), `stop` retains the snapshot and
starting the same ID restores it. `persistence :temporary` deletes it on stop.
Both checkpoint while running. Synchronization defaults to periodic dirty-state saves
every 30 seconds. Configure `sync: %{mode: :periodic, interval_ms: 5_000}` at start;
`:automatic` enables native callback sync and `:explicit` requests strict sync on
persistent transitions. Children inherit this policy unless overridden. Processing
receipts in periodic mode do not promise a storage commit. The separate `delete` action stops an agent and
removes its snapshot regardless of retention, including by ID after stop.
Recovery does not replay in-flight tools or resume a waiting Lua VM.

`Aikido.Agent.Extension` is a resource extension. Choosing a separate Ash data layer does
not automatically persist live agent state or make process effects transactional.

## State and effects

External domain commands run through `Aikido.Agent.Commands` in `agent/commands/`.
They perform runtime I/O such as starting agents and delivering signals. Inside
the agent pipeline, reducer implementations live in their owning `actions/` folders.

Reducer actions are pure: they return the next state and directives and never perform
side effects. Their return values are the sole channel for domain state changes.
All side effects belong in directives: message delivery, network and database I/O,
process creation and timers. Directives perform I/O
and mutate no domain or runtime state. Their results return as signals, which
enter another action. Middleware may stage an agent for I/O; runtime bookkeeping
belongs to runtime callbacks. Use Ash types for data contracts and Spark for DSL
and configuration validation.

## Guides and examples

- [Ash domains, agents, slices, and teams](guides/ash-integration.md)
- [Team topology and lifecycle](guides/teams.md)
- [Runtime patterns and durability](guides/runtime-patterns.md)
- [Partitions and multi-tenancy](guides/multi-tenancy.md)
- [Runnable Phoenix/LiveView examples](examples/agent_app/README.md)
- [AI tools and orchestration examples](examples/agent_app/AI.md)

## Development

```bash
mix deps.get
mix test
mix q
mix docs
```

`mix q` includes all Argus BEAM analyses alongside formatting, compilation,
Credo and Dialyzer, with no suppressed Argus findings. Run `mix argus --all`
separately to inspect its findings. Missing analysis engines fail the check.
The first run downloads verified analysis engines; subsequent runs reuse the
local cache. CI caches these engines with the build dependencies.

See [Contributing](CONTRIBUTING.md) and [Changelog](CHANGELOG.md).

Aikido is derived from Jido and is developed independently. Original copyright
notices and the Apache 2.0 license are retained.

### Context summary recovery

Set `handoff_max_regenerations` in AI execution `options` to allow additional
summary generations after an empty, invalid or oversized handoff document.
The default is `0`, preserving failure without changing conversation history.
The conversation example enables one regeneration. Each regeneration requests
corrective output from the original history with a fresh handoff ID. It keeps
the run deadline, caller scope, model options and accumulated usage. With `R`
regenerations and `M` model retries, at most `(R + 1) * (M + 1)` provider attempts
are made for that handoff, subject to cancellation and remaining time.

Truncated summaries remain failures: the runtime has no verified output ceiling
for safely increasing their output budget. Provider, permission and configuration
failures do not trigger summary regeneration; eligible provider failures retain
the existing `model_max_retries` policy. Recovery interrupts an in-flight summary
rather than replaying it. No invalid summary replaces retained history.
