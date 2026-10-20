# AGENTS.md - Aikido Guide

## Intent
Build reliable agent systems by separating pure decision logic from runtime side-effect execution.

## The Bright Line
- **Actions are pure.** They return the next state and directives and must never perform side effects. The action's return value is the **sole channel** for `agent.state` (domain) writes.
- **Directives are pure I/O.** They emit signals, spawn processes, schedule messages — and **mutate no state**: not domain (`agent.state`), not runtime (`%AgentServer.State{}`), nothing. Their results, if any, come back as signals that re-enter the pipeline.
- **Type-system enforced.** `Aikido.Directive.exec/3` returns `:ok | {:stop, term()}` — there is no state slot in the return shape, so a directive author cannot accidentally write one.

Sole exception: middleware may stage `ctx.agent` for I/O purposes. The state/effect separation rules in this file are canonical.

## Action/Directive Design Rules
- Side effects belong only in directives. Actions must not send messages, perform network or database I/O, spawn processes, or schedule timers; return directives for that work.
- Actions are the only place that decides and applies agent state transitions. If another process needs state changed, send it a signal and let that process route the signal to an action.
- Directives should be as short as possible: one runtime effect, then return. Do not put multi-step workflows inside a directive’s `exec/3` callback.
- Directives must not call `Aikido.AgentServer.call/4`, wait for replies, inspect agent state to decide business logic, or mutate process state. Synchronous calls from directive execution can deadlock when the target is the current agent or is waiting on the current mailbox turn.
- For expensive or blocking work, use `Aikido.Directives.AsyncTask`. The task does one unit of work and returns a result signal (or `{:ok, value}` / `{:error, reason}` for the directive to wrap). The receiving action handles the result and returns the next directive if more work remains.
- For cross-agent communication, prefer existing signal delivery directives (`Emit` or app-specific cast descriptors) that deliver one signal. The receiving action owns any state changes and may queue the next signal/directive.
- Model workflows as signal chains: `action -> directive -> signal -> action -> directive`. Each action changes state at most for its own agent/slice, then returns the next small directive.
- Never use debug helpers such as `:sys.replace_state/2` in normal runtime code. If a state update is needed, expose a routed action that updates state through the agent pipeline.

## Runtime Baseline
- Elixir `~> 1.19`
- OTP `28+` (release QA baseline)

## Commands
- `mix test` (full suite; no default tag exclusions)
- `mix test --cover` (coverage gate)
- `mix q` or `mix quality` (`format --check-formatted`, `compile --warnings-as-errors`, `credo`, `dialyzer`)
- `mix docs` (local docs)

## Architecture Snapshot
- `Aikido.Agent`: immutable identity/state struct and a convenience macro over `Ash.Resource` with `Aikido.Ash.Agent`
- `Aikido.Ash.Agent`: resource extension that compiles state declarations into attributes and exposes generic lifecycle/signal actions
- `Aikido.Ash.Domain`: domain interfaces named `<agent>_<action>`; start returns a reference, signal commands return processing receipts, and inspect/list explicitly read live state
- `Aikido.Ash.Slice`: embedded resource extension; slices own their attributes, native reducer actions and routes
- `Aikido.Ash.Team`: topology and coordination on an agent resource, including nested teams and dynamic workers
- `Aikido.AgentServer`: signal routing, native Ash reducer execution, directive execution and runtime bookkeeping, hosted by DurableServer
- `Aikido.Directive`: Spark/Ash typed-struct host and execution behaviour; concrete descriptors live under `Aikido.Directives` or their owning feature
- `Aikido.Types.ActionResult`: typed reducer result containing next state and validated directives
- `Aikido.Durable`: keyed activation and persistence through DurableServer; the default backend is local EKV

## Native Ash and Spark Contracts
- Define reducer actions on their owning agent or slice resource, with typed `argument`s and `Aikido.Types.ActionResult` as the return type. Prefer separate `Ash.Resource.Actions.Implementation` modules referenced with `run MyApp.Implementation`.
- A signal target is a required positional local action name or `{resource, action}` tuple. Mounted slices contribute their routed public actions; do not redeclare them on the agent.
- Let native Ash changesets and action inputs apply types, constraints and defaults. Use Spark Info modules for DSL metadata, transformers for expansion and verifiers for validation. Avoid generated companion resources, custom validation bridges and redundant accessor functions.
- Forward native Ash/Spark options in convenience hosts. Use an application domain when supplied; `Aikido.RuntimeDomain` is the agent convenience macro's default. Keep normal domain-inclusion validation.
- Pass actor, tenant, application context and tracers through native Ash scope and tracing APIs. The external command and internal reducer are separate Ash authorization boundaries; downstream tools retain their own authorization.
- Supply AI tools as Ash AI tool names plus native `tool_options`. Tool setup builds descriptions and registry once per run. Prepared callbacks are transient and are rebuilt for a new run.
- The purity rules apply to agent/slice state reducers. Public lifecycle/signal adapters and tool implementations are I/O boundaries, not reducers; invoke tools through directives or supervised work rather than from a reducer.

## Persistence and Completion
- DurableServer is the sole persistence/activation path. Do not introduce parallel storage adapters or an instance manager.
- Start application agents through domain actions. Lifecycle action implementations and spawning directives call `Aikido.Durable` directly; do not add a parallel lifecycle facade. Add the Aikido runtime to the application supervision tree once; agents share its DurableServer supervisor and are not linked to command callers.
- `persistence :permanent` retains snapshots on stop; `:temporary` deletes them on stop. Both checkpoint while running. The separate `delete` action removes the saved identity regardless of retention. `restart?` controls automatic crash recovery independently of retention.
- Use paired `externalize/1` and `reinstate/1` callbacks for path state, or paired agent-wide `checkpoint/2` and `restore/2`, to control snapshot content. Keep credentials and runtime-only closures out of persisted configuration. A separate Ash data layer does not persist the live agent automatically.
- Local EKV requires its disk to survive; it does not by itself provide machine-loss protection. Recovery does not replay external effects or resume in-flight Lua VMs.
- Subscribe before triggering asynchronous work. Use one-shot subscriptions or `Aikido.AgentServer.call_until/5` from external callers. Never poll for completion, and never wait for completion inside directive execution.

## Standards
- Keep Ash reducer actions pure: the same input returns the same state and directives
- Directives mutate **no** state — neither `agent.state` (domain) nor `%AgentServer.State{}` (runtime). State changes flow through the action's return value; runtime bookkeeping flows through GenServer callbacks and `process_signal/2` cascade callbacks
- Use **Ash types** for data contracts and **Spark.Options** for DSL/configuration validation
- Preserve tagged tuple and structured error contracts at public boundaries
- Keep cross-agent communication on signals/directives, not ad-hoc process messages
- Use the Spark formatter's DSL rules and omit parentheses on DSL keys. Use multiline heredocs for multiline documentation and scripts.
- Comments describe current behavior; omit retired task numbers, ADR references and migration history.

## Testing and QA
- Prefer pure agent tests first, then AgentServer/runtime integration tests
- Use helpers from `test/AGENTS.md` (`AikidoTest.Case`, `AikidoTest.AgentWait`, `AikidoTest.LifecycleWait`) for async assertions
- Avoid `Process.sleep/1` in tests; assert eventual state/event behavior

## Release Hygiene
- Keep dependency ranges stable; change them deliberately and verify compatibility.
- Use Conventional Commits
- Update `CHANGELOG.md`, guides, and examples for behavior/API changes

## References
- `README.md`
- `usage-rules.md`
- `guides/`
- `test/AGENTS.md`
- https://github.com/barnabasJ/aikido
