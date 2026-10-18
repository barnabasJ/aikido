# Aikido Usage Rules

## Intent
Build reliable multi-agent systems by keeping decision logic pure and runtime effects explicit.
<!-- package.aikido.pure_cmd package.aikido.runtime_separation -->

## The Bright Line
- **Actions mutate state.** The action's return value is the **sole channel** for `agent.state` writes.
- **Directives are pure I/O.** They mutate **no** state — neither domain (`agent.state`) nor runtime (`%AgentServer.State{}`). Results, if any, return as signals that re-enter the pipeline.
- **Type-system enforced.** `Aikido.AgentServer.DirectiveExec.exec/3` has no state slot in its return shape (`:ok | {:stop, term()}`).

Sole exception: middleware may stage `ctx.agent` for I/O purposes. The state/effect separation rules in this file are canonical.

## Core Contracts
- Treat `cmd/2` as the core agent contract: `{updated_agent, directives}`.
- Keep agent logic pure. Directives are pure I/O — they describe external effects and never mutate state of any kind.
- Use **Ash types** for data contracts and **Spark.Options** for DSL/configuration validation.
- Preserve tagged tuple and structured error contracts at public boundaries.
- Use AgentServer/runtime modules for process concerns, not agent module internals.

## Library Author Patterns
- Author actions for domain behavior; let agents orchestrate state + directive emission.
- Use `Directive.SpawnAgent` / `Directive.StopChild` for hierarchy, not ad-hoc child tracking.
- Use signals for cross-agent communication instead of direct process coupling.
- Keep plugin/sensor concerns isolated and composable.

## QA Patterns
- Start with pure `cmd/2` tests, then add AgentServer integration tests.
- Use `AikidoTest.Case` + `AikidoTest.Eventually` for async runtime assertions.
- Run `mix q` (`mix quality`) and coverage checks before release.

## Avoid
- Embedding runtime side effects directly in core state transition code.
- Using directives as a hidden state-mutation mechanism — they are pure I/O.
- Mutating `%AgentServer.State{}` runtime fields (`children`, `cron_*`, etc.) from inside a directive's `exec/3` body. Runtime bookkeeping belongs in the GenServer callbacks and signal-cascade callbacks invoked by `process_signal/2`.
- Tight coupling between unrelated agent modules.

## References
- `README.md`
- `guides/`
- `test/AGENTS.md`
- `AGENTS.md`
- https://github.com/barnabasJ/aikido
- https://hexdocs.pm/usage_rules/readme.html#usage-rules
