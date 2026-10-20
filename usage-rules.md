# Aikido Usage Rules

## Intent
Build reliable multi-agent systems by keeping decision logic pure and runtime effects explicit.
<!-- package.aikido.pure_actions package.aikido.runtime_separation -->

## The Bright Line
- **Actions are pure.** They return the next state and directives and must never perform side effects. The action's return value is the **sole channel** for `agent.state` writes.
- **Side effects belong only in directives.** They mutate **no** state — neither domain (`agent.state`) nor runtime (`%AgentServer.State{}`). Results, if any, return as signals that re-enter the pipeline.
- **Type-system enforced.** `Aikido.AgentServer.DirectiveExec.exec/3` has no state slot in its return shape (`:ok | {:stop, term()}`).

Sole exception: middleware may stage `ctx.agent` for I/O purposes. The state/effect separation rules in this file are canonical.

## Core Contracts
- Define reducers as native Ash actions returning `Aikido.Types.ActionResult`.
- Keep agent logic pure. Actions must not send messages, perform network or database I/O, spawn processes, or schedule timers. Return directives for all side effects; directives never mutate state of any kind.
- Use **Ash types** for data contracts and **Spark.Options** for DSL/configuration validation.
- Preserve tagged tuple and structured error contracts at public boundaries.
- Use AgentServer/runtime modules for process concerns, not agent module internals.

## Library Author Patterns
- Author actions for domain behavior; let agents orchestrate state + directive emission.
- Use `Directive.SpawnAgent` / `Directive.StopChild` for hierarchy, not ad-hoc child tracking.
- Use signals for cross-agent communication instead of direct process coupling.
- Keep slice state and actions isolated and composable.

## QA Patterns
- Start with pure Ash action tests, then add AgentServer integration tests.
- Use `AikidoTest.Case`, subscription helpers and process monitors for async runtime assertions.
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
