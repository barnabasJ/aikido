# AGENTS.md - Aikido Guide

## Intent
Build reliable agent systems by separating pure decision logic from runtime side-effect execution.

## The Bright Line
- **Actions are pure.** They return the next state and directives and must never perform side effects. The action's return value is the **sole channel** for `agent.state` (domain) writes.
- **Directives are pure I/O.** They emit signals, spawn processes, schedule messages — and **mutate no state**: not domain (`agent.state`), not runtime (`%AgentServer.State{}`), nothing. Their results, if any, come back as signals that re-enter the pipeline.
- **Type-system enforced.** `Aikido.AgentServer.DirectiveExec.exec/3` returns `:ok | {:stop, term()}` — there is no state slot in the return shape, so a directive author cannot accidentally write one.

Sole exception: middleware may stage `ctx.agent` for I/O purposes. The state/effect separation rules in this file are canonical.

## Action/Directive Design Rules
- Side effects belong only in directives. Actions must not send messages, perform network or database I/O, spawn processes, or schedule timers; return directives for that work.
- Actions are the only place that decides and applies agent state transitions. If another process needs state changed, send it a signal and let that process route the signal to an action.
- Directives should be as short as possible: one runtime effect, then return. Do not put multi-step workflows inside `DirectiveExec`.
- Directives must not call `Aikido.AgentServer.call/4`, wait for replies, inspect agent state to decide business logic, or mutate process state. Synchronous calls from directive execution can deadlock when the target is the current agent or is waiting on the current mailbox turn.
- For expensive or blocking work, use `Aikido.Directives.AsyncTask`. The task does one unit of work and returns a result signal (or `{:ok, value}` / `{:error, reason}` for the directive to wrap). The receiving action handles the result and returns the next directive if more work remains.
- For cross-agent communication, prefer existing signal delivery directives (`Emit` or app-specific cast descriptors) that deliver one signal. The receiving action owns any state changes and may queue the next signal/directive.
- Model workflows as signal chains: `action -> directive -> signal -> action -> directive`. Each action changes state at most for its own agent/slice, then returns the next small directive.
- Never use debug helpers such as `:sys.replace_state/2` in normal runtime code. If a state update is needed, expose a routed action that updates state through the agent pipeline.

## Runtime Baseline
- Elixir `~> 1.19`
- OTP `28+` (release QA baseline)

## Commands
- `mix test` (default alias excludes `:flaky`)
- `mix test --include flaky` (full suite)
- `mix test --cover` (coverage gate)
- `mix q` or `mix quality` (`format --check-formatted`, `compile --warnings-as-errors`, `credo`, `dialyzer`)
- `mix docs` (local docs)

## Architecture Snapshot
- `Aikido.Agent`: pure agent module with immutable state and `cmd/2`
- `Aikido.AgentServer`: GenServer runtime for directives, lifecycle, and message flow
- `Aikido.Agent.Directive.*`: typed pure-I/O descriptors (`Emit`, `SpawnAgent`, `StopChild`, etc.)
- Slices provide capability composition without coupling core agent logic

## Standards
- Keep `cmd/2` pure: same input => same `{agent, directives}` output
- Directives mutate **no** state — neither `agent.state` (domain) nor `%AgentServer.State{}` (runtime). State changes flow through the action's return value; runtime bookkeeping flows through GenServer callbacks and `process_signal/2` cascade callbacks
- Use **Ash types** for data contracts and **Spark.Options** for DSL/configuration validation
- Preserve tagged tuple and structured error contracts at public boundaries
- Keep cross-agent communication on signals/directives, not ad-hoc process messages

## Testing and QA
- Prefer pure agent tests first, then AgentServer/runtime integration tests
- Use helpers from `test/AGENTS.md` (`AikidoTest.Case`, `AikidoTest.AgentWait`, `AikidoTest.LifecycleWait`) for async assertions
- Avoid `Process.sleep/1` in tests; assert eventual state/event behavior

## Release Hygiene
- Keep semver ranges stable (`~> 2.0` for Aikido ecosystem peers)
- Use Conventional Commits
- Update `CHANGELOG.md`, guides, and examples for behavior/API changes

## References
- `README.md`
- `usage-rules.md`
- `guides/`
- `test/AGENTS.md`
- https://github.com/barnabasJ/aikido
