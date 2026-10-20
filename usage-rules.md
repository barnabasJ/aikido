# Aikido Usage Rules

## Intent
Build reliable multi-agent systems by keeping decision logic pure and runtime effects explicit.
<!-- package.aikido.pure_actions package.aikido.runtime_separation -->

## The Bright Line
- **Actions are pure.** They return the next state and directives and must never perform side effects. The action's return value is the **sole channel** for `agent.state` writes.
- **Side effects belong only in directives.** They mutate **no** state — neither domain (`agent.state`) nor runtime (`%AgentServer.State{}`). Results, if any, return as signals that re-enter the pipeline.
- **Type-system enforced.** `Aikido.Directive.exec/3` has no state slot in its return shape (`:ok | {:stop, term()}`).

Sole exception: middleware may stage `ctx.agent` for I/O purposes. The state/effect separation rules in this file are canonical.

## Core Contracts
- Define reducers as native Ash actions returning `Aikido.Types.ActionResult`.
- Keep agent logic pure. Actions must not send messages, perform network or database I/O, spawn processes, or schedule timers. Return directives for all side effects; directives never mutate state of any kind.
- Use **Ash types** for data contracts and **Spark.Options** for DSL/configuration validation.
- Preserve tagged tuple and structured error contracts at public boundaries.
- Use AgentServer/runtime modules for process concerns, not agent module internals.

## Public API and Persistence
- Declare agents as `Ash.Resource`s with `Aikido.Ash.Agent`, and register them in an `Ash.Domain` with `Aikido.Ash.Domain`. `use Aikido.Agent` forwards native resource options and supplies `Aikido.RuntimeDomain` only when no domain is provided.
- Put reducer contracts on the owning agent or embedded slice resource. Prefer separate `Ash.Resource.Actions.Implementation` modules for `run/3`. Signal targets are local action names or `{resource, action}` tuples.
- Use generated `<agent>_<action>` domain interfaces. `start` returns a reference; signal commands return processing receipts. Read live state explicitly with `inspect` or `list`; observe asynchronous completion with subscriptions or `Aikido.AgentServer.call_until/5` from an external caller.
- `Aikido` sets up runtime supervision and configuration; it does not expose agent lifecycle shortcuts. Domain action implementations use `Aikido.Durable` directly.
- DurableServer owns activation, snapshots and recovery. `persistence :permanent` retains a snapshot on stop; `:temporary` deletes it on stop. Both checkpoint while running. The separate `delete` action removes the durable identity regardless of retention.
- Use slice/agent `externalize/1` and `reinstate/1`, or agent-wide `checkpoint/2` and `restore/2`, to control snapshot content. Keep credentials and runtime-only functions out of persistent configuration. A different Ash data layer does not persist the live process state.
- Pass native Ash actor, tenant, context and tracer options at command boundaries. Authorization of a public command does not replace authorization of its reducer or tools. Use Ash tracing APIs to transfer context into custom asynchronous work.
- Supply AI tools as Ash AI tool names plus native `tool_options`. Setup builds the tool descriptions and registry once per run; callers do not wrap executable callbacks.

## Library Author Patterns
- Author actions for domain behavior; let agents orchestrate state + directive emission.
- Use `Aikido.Directives.SpawnAgent` / `Aikido.Directives.StopChild` for hierarchy, not ad-hoc child tracking.
- Use signals for cross-agent communication instead of direct process coupling.
- Keep slice state and actions isolated and composable.

## QA Patterns
- Start with pure Ash action tests, then add AgentServer integration tests.
- Subscribe before triggering work; use one-shot subscriptions and process monitors for async assertions. In this repository, `AikidoTest.Case` supplies test isolation; it is not a public library API.
- Run `mix q` (`mix quality`) and coverage checks before release.

## Avoid
- Embedding runtime side effects directly in core state transition code.
- Using directives as a hidden state-mutation mechanism — they perform I/O only.
- Mutating `%AgentServer.State{}` runtime fields (`children`, `cron_*`, etc.) from inside a directive's `exec/3` body. Runtime bookkeeping belongs in the GenServer callbacks and signal-cascade callbacks invoked by `process_signal/2`.
- Tight coupling between unrelated agent modules.

## References
- `README.md`
- `guides/`
- `test/AGENTS.md`
- `AGENTS.md`
- https://github.com/barnabasJ/aikido
- https://hexdocs.pm/usage_rules/readme.html#usage-rules
