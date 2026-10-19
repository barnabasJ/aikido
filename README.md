# Aikido

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

## An agent and its public interface

Define native Ash actions directly on an agent or on a mounted slice. Runtime
state is supplied internally; each action returns `Aikido.ActionResult`:

```elixir
defmodule MyApp.Counter do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [Aikido.Ash.Agent]

  agent do
    name "counter"

    schema do
      attribute :count, :integer, allow_nil?: false, default: 0, public?: true
    end

    signal :add, "counter.add", :add
  end

  actions do
    action :add, Aikido.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :amount, :integer, allow_nil?: false

      run MyApp.Increment
    end
  end
end

defmodule MyApp.Increment do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    Aikido.ActionResult.new(state: %{state | count: state.count + input.arguments.amount})
  end
end

defmodule MyApp.Agents do
  use Ash.Domain, otp_app: :my_app, extensions: [Aikido.Ash.Domain]

  agents do
    agent :counter, MyApp.Counter
  end
end
```

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
public actions automatically.

## Teams, AI, and persistence

Add `Aikido.Ash.Team` for fixed members, dynamic workers, ownership, dependencies,
and nested teams. A team can accept its initial `topology` in the start call.
Add `Aikido.Ash.AI` for model turns; pass the model, tools, and optional prompt and
iteration settings at runtime. AshAI and AshLua tools can expose management and
delegation capabilities to AI agents.

The default runtime uses DurableServer. Configure a persistent data directory or
backend for the deployment. Snapshot recovery preserves logical agent state and
team topology; it rebuilds runtime membership and monitors. IDs remain stable
when PIDs change. Agent and slice serialization callbacks remain available.

`Aikido.Ash.Agent` is a resource extension. Choosing a separate Ash data layer does
not automatically persist live agent state or make process effects transactional.

## State and effects

Actions are pure: they return the next state and directives and never perform
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

See [Contributing](CONTRIBUTING.md) and [Changelog](CHANGELOG.md).

Aikido is derived from Jido and is developed independently. Original copyright
notices and the Apache 2.0 license are retained.
