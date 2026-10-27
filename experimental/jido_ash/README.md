# Experimental Jido v3 → Ash adapter

This opt-in adapter exposes a Jido agent's named inputs through native Ash generic
actions and code interfaces. Jido owns execution, live state, supervision and
persistence. The adapter has no state store or Aikido AgentServer dependency.
It is a separate Mix project so the experimental dependency graph does not change
Aikido's runtime dependencies.

The implementation targets Jido `release/v3`, version `3.0.0-beta.2`, pinned at
[`aaca071`](https://github.com/agentjido/jido/tree/aaca071c90691662c7036fe4d71ab63e6ee3432a).
Its pinned `jido_action` is `3.0.0-beta.22` and Zoi is `0.18.11`.
This is not a compatibility claim for Jido v2 or future v3 revisions.

```elixir
defmodule Counter do
  use Jido.Agent, name: "counter"
  use Aikido.Jido

  state do
    schema Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)})
  end

  routes do
    signal_source "/counter"

    route "counter.add", as: :add do
      action %{amount: amount},
        schema: Zoi.object(%{amount: Zoi.integer() |> Zoi.min(1)}),
        context: context do
        {:ok, %{count: context.agent_state.count + amount}}
      end
    end
  end
end

# Use a live Jido worker address or Jido's supported reference form.
{:ok, {:ok, agent, directives}} = Counter.ash_add(%{server: server, amount: 2})
{:ok, :ok} = Counter.ash_add_cast(%{server: server, amount: 2})
{:ok, pending} = Counter.ash_add_submit(%{server: server, amount: 2})
{:ok, agent, directives} = Jido.AgentServer.await(pending)
{:ok, {:ok, signal}} = Counter.ash_add_signal(%{amount: 2})

# These are ordinary code interfaces on the generated resource too.
Counter.Ash.add(%{server: server, amount: 2}, actor: actor, tenant: tenant)
Counter.ash_resource() # Counter.Ash
```

The compiled example is `Aikido.Jido.Examples.Counter`. When starting a native
Jido child specification, its result is an activation supervisor. Obtain its
worker with `Jido.AgentServer.worker(activation)` before using a PID address.

## Contract derivation

The adapter reads the finalized `definition().routes` after Jido compilation.
Jido has no `public?` API registry at this revision: `as:` is the explicit marker
that creates a public named signal helper. Only these routes become interfaces;
unnamed executable routes stay internal. Both Action and Flow handlers use their
native `schema/0`. No second operation list or handler execution is involved in
generation.

Each named route produces `name`, `name_cast`, `name_submit` and `name_signal`.
The first three directly call Jido's `call/3`, `cast/3` and `submit/3`. Signal
construction calls Jido's existing input-signal builder. Each operation has its
own generated implementation module. A simple same-module Jido/Ash probe compiled
with conflicting `input/1` and `input/2` clauses and Spark verifier warnings;
this prototype uses a nested Ash resource and agent-facing helpers instead.

| Zoi input | Ash argument |
| --- | --- |
| Integer / float | `:integer` / `:float`, inclusive bounds |
| String | `:string`, length bounds, grapheme counting, no trimming |
| Boolean / atom | `:boolean` / `:atom` |
| Any | `:term` |
| Object / map | `:map`, recursively typed object fields |
| Array | `{:array, item_type}`, item/null and length constraints |
| Nullable type | inner type with `allow_nil?` |
| Atom / string enum | atom membership / exact string pattern |
| Date / DateTime | `:date` / `:utc_datetime_usec` |

Arguments expose descriptions, optionality, Zoi defaults and route defaults.
Route defaults take precedence. Tuple-shaped data defaults are protected from
accidental Ash MFA execution. Full Zoi constraints, refinements, transforms,
coercion and default rules remain authoritative during Jido execution. Ash casts
for its own validation and authorization; dispatch deliberately uses original
parameter values, so a strict Zoi integer still rejects `"2"`. The adapter does
not run Zoi effects a second time. Builders do not execute handlers or full Zoi
validation. Cast submission does not acknowledge validation or commit.

## Results and scope

An Ash boundary failure returns `{:error, ash_error}`. An accepted Ash action
returns `{:ok, native_jido_result}`. The inner value preserves the original tagged
success/error, directives, pending handle or `:ok`. OTP call timeout exits are not
caught or converted. Pending handles retain Jido's original caller ownership and
must be awaited or abandoned through Jido from that process.

Native Ash actor, tenant, authorization and context options apply at the generated
resource boundary. Configure `authorizers: [MyAuthorizer]` and `extensions: [...]`
on `use Aikido.Jido`; the default resource has no authorization policy. Supply
`domain: MyDomain` to use an application domain and register `MyAgent.Ash` there
normally. Otherwise a shared internal domain accepts the generated resources.

Native scope, tracer metadata and span contexts captured with `Ash.Tracer` reach
the Jido turn as `context.ash`; user
`runtime_options[:context][:ash]` cannot overwrite it. Other Jido turn context
remains available. This does not turn downstream Jido work into an Ash action or
authorize its external tools automatically. `runtime_options` and `signal_options`
are passed to the corresponding native Jido boundaries.

## Deliberate limits

- The first slice covers named Action and Flow routes, not lifecycle operations,
  topology, forwarding/transform routes or arbitrary internal actions.
- Root input schemas must be Zoi objects with atom keys. Reserved top-level names
  are `server`, `runtime_options` and `signal_options`; name collisions fail at
  compilation. Unsupported unions, tuples, literals and other unmapped types
  produce explicit compile-time errors.
- Ash rejects extra top-level inputs even when Zoi would strip or retain them.
  Nested/dynamic-map constraints beyond the native projection remain checked by
  Jido. Optional missing keys and explicit nil keep their original Zoi meaning.
- Dispatch uses the original params; Ash preparations that rewrite argument values
  are not an input-transformation API for this prototype.
- Resources are regenerated when their agent recompiles. Changes to referenced
  executable schemas require recompiling the agent. This is an experimental
  compile-time adapter, not a hot-reload contract.

## Run

```sh
cd experimental/jido_ash
mix deps.get
mix test
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
```

The tests exercise actual v3 Action/Flow runtime dispatch, state adoption,
authorization and scope, strict Zoi validation, schema mapping, cast and submit
semantics, compilation diagnostics, and generated BEAM persistence.
See [BASELINE.md](BASELINE.md) for the preserved Aikido work and verification.
