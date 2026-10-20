# CHANGELOG

<!-- changelog -->

## Unreleased

### Changed

- Process logical cron cancellation in registration order before retiring ownership
  and starting supervised shutdown. Replacement cleanup targets the captured old
  process directly, so late shutdown cannot cancel a newly registered job.

- Exclude provider-executed builtin tools from interruption repair while keeping
  canonical conversation content and provider metadata intact. Repair only missing
  application tool results across subsequent asks and restoration.

- Inherit public mounted actions from local and remote tuple targets, preserve
  route predicates and priorities, and generate one canonical command for a
  reducer with multiple signal types. Deduplicate identical normalized mount
  routes so each mounted path runs once per matching dispatch.

- Run the configured high-priority Credo checks instead of an empty priority
  selection. Simplify the local constructs they flag, remove obsolete Dialyzer
  suppression and unused test helpers, and refresh native-action test descriptions.

- Compute deterministic Memory/Thread initialization IDs only when creating missing
  state; existing-state mutations retain identities and use signal timestamps
  without serializing and hashing the full history.

- Preserve already encoded snapshots during DurableServer's initialization-lock
  checkpoint instead of rebuilding defaults or rerunning codecs. Verify state,
  logical parent bindings and saved cron definitions across repeated dumps.

- Preserve supplied state in effect-only built-in reducers; remove incidental
  tracking fields. Cancel alone validates and applies its status/error transition
  without evaluating resource update defaults. Run child startup as supervised
  work and retain parent-death policies during delayed activation.
- Give generated cron occurrences fresh envelopes, retain explicit signal
  identities, and correlate directive telemetry and bounded failure logs with
  the originating signal ID.

- Settle rejected model/tool task starts through correlated result signals and
  preserve caller scope. Enforce positive ReAct iteration limits with native
  constraints and simplify task cleanup and normalized run-state handling.

- Resolve all local reducer routes after public command renaming, allow team
  members named `nodes`, and distinguish slice schedules by their full normalized
  declaration. Deduplicate shared schedule routes and reject colliding agent job
  IDs through Spark verification; explicit agent `job_id` values remain supported.

- Flatten team send arguments to native `member`, `type` and `payload` fields.
  Share ownership traversal and simplify topological ordering; preserve explicit
  nil slice configuration and explicit false FSM initialization values.
- Restrict persisted Lua request callbacks to portable external function captures
  through Ash's `mfa: true` constraint. Pass per-run callback configuration in
  event metadata. Preserve caller scope and tracing in Lua-emitted signals;
  finish model responses with no executable tool calls without stranding a run.
- Retire cron ownership before supervised shutdown, clean replacement/restart
  bookkeeping consistently, and preserve replacement jobs when old work completes.
  Isolate raising observers and blocking dispatch adapters from committed state;
  retain directive debug events and restore team metadata in the right partition.
- Reconcile example subscriptions by path and process incarnation, remove unused
  test fixtures and the Mock dependency, and align contributor instructions and
  logger metadata with the current implementation.


- Remove the `Aikido.Ash` forwarding facade. Invoke lifecycle and signal actions
  through application domain interfaces or native `Ash.ActionInput` and
  `Ash.run_action`; update example callers and tests accordingly.
- Infer public team command contracts from their owning reducers. Use native Ash
  defaults and casting for startup, AI directive options, memory spaces and thread
  entries, removing duplicate schema and normalization code.
- Simplify runtime startup validation, directive dispatch and scheduling. Remove
  unused lifecycle wrappers and stale signal-extension registrations; validate
  agent modules through Ash's behaviour constraint.
- Remove the unused `Aikido.Observe` facade, logger and span context wrappers and
  their configuration. Active telemetry configuration now lives in
  `Aikido.Telemetry.Config`; tracing continues through native Ash APIs.
- Remove the obsolete Livebook verification script and repair the action benchmark
  fixture to construct a typed memory space.

- Keep `Aikido` focused on runtime supervision and configuration. Remove its
  agent lifecycle, lookup and enumeration entry points; domain action
  implementations and spawning directives call `Aikido.Durable` directly.
  Remove the redundant debug and UUID shortcuts in favor of `Aikido.Debug`
  and `Ash.UUIDv7`.

- Remove AgentServer startup wrappers. Start application agents through their
  Ash domain actions, with one internal activation path through DurableServer.
  Runtime tests use that internal path without linking agents to the caller.

- Use Ash typed structs for AI execution options and Lua hook decisions instead
  of data-only embedded resources. Cast parent references and validate
  parent-death policies through native startup option field types.

- Cast slice configuration directly with Ash's constrained map type after
  resolving defaults and overrides. Read config declarations from Spark entities;
  remove the generated config action and its passthrough implementation.

- Forward native Ash resource options through `use Aikido.Agent` and
  `use Aikido.Slice`, preserving caller domains, authorizers and extensions.
  Keep ordinary domain-inclusion validation enabled, remove redundant overrides
  from embedded resources, and forward Spark options through `use Aikido`.

- Move the shared action return contract to `Aikido.Types.ActionResult`. Generate
  public signal arguments directly from native Ash argument metadata and remove
  the redundant `Aikido.ActionRef` schema conversion helper.

- Use native Ash tracer contexts across signal, directive and asynchronous task
  boundaries. Remove Aikido's separate trace IDs and process-dictionary tracing;
  preserve span ancestry through AI work and result signals, and restore context
  after each turn. Add a full external-action-to-final-state tracing test.

- Align test fixtures with native Ash action implementations and DurableServer
  supervision. Remove unused resources, adapter options and duplicate schema
  wrapper tests; consolidate FSM coverage and run the full suite without default
  tag exclusions.

- Remove the local LM Studio ReAct test suite and its unused echo fixture; retain
  deterministic mock integration coverage for answers, tools and subscriptions.

- Standardize agent and slice declarations on native Ash resources. Remove the
  parallel DSL hosts, implicit default mounts, contributed-section machinery,
  single-action fixture resources and action-module inference. Use Spark entity
  identifiers, native argument builders and Ash errors.

- Standardize process activation and recovery on DurableServer. Remove Poolboy,
  the local registry path and unused managed-spawn APIs. Use `restart?` for
  automatic recovery and `persistence` for snapshot retention. Reads and runtime
  subscriptions no longer dump durable snapshots.

- Preserve native ReqLLM responses and message metadata; reuse Ash AI's pending
  tool-call and error helpers. Remove ChildBus and obsolete schema/option helpers.
  Use `Ash.Tracer` for tracing and Ash TypedStruct constructors for contracts.

- Validate raw action results and directive fields before applying state or
  effects. Keep adoption asynchronous, preserve caller scope in team startup,
  retain scheduled payloads and route predicates, and remove unused configuration,
  telemetry, dependencies and test adapters.

- Replace the Native validation wrapper with native Ash atom constraints and
  typed arrays of key/value tuples for open keyword options. Preserve arbitrary
  tool/provider keys without a custom cast implementation.

- Move agent, slice, domain, AI and composition declaration checks into Spark
  verifiers. Delegate field uniqueness to Ash; keep construction preconditions
  with the transformations that require them.

- Validate team declarations and topology with a Spark verifier after compilation;
  the team transformer only assembles configuration and generates actions.

- Remove unused plugin-action metadata, reserved slice aliases and path-override
  handling, ignored route options, unused timeout defaults and path-conflict
  exceptions, unused action formatting and schema identity wrappers. Use native
  Ash types directly. Update examples and introspection docs to describe native Ash
  action references and agent-declared slice mounts.

- Use DurableServer as the sole persistence path. Remove Storage adapters,
  explicit hibernate/thaw, persistence middleware, separate thread stores and
  scheduler manifests embedded in domain state. Keep agent and slice codecs
  under `Aikido.Durable.Codec`, and retain complete thread history in snapshots.

- Remove the outdated installer and agent generator, their templates and tests,
  and the direct Igniter dependency. Start the default runtime with `Aikido`, or
  define a custom runtime module with `use Aikido, otp_app: :my_app`.

- Run AgentServer directly on the original Ash resource. Remove generated
  companion resources and resource/runtime mappings. Initialize typed state
  through native Ash changesets without writing the configured data layer.

- Store agent state fields, AI flags and team configuration in Spark instead of
  generating functions on every resource.
  Read it through `Aikido.Dsl.Agent.Info`.

- Replace generated agent constructors, setters and whole-agent validators with
  a configured native initialization action and Ash code interface. Embedded
  resource create/update actions own defaults, casting and validation.

- Dispatch signals directly to native Ash actions in AgentServer. Remove the
  generated agent command API, custom instructions, executor and RunInstruction
  directive. Keep state transitions atomic and execute effects after success.

- Remove unused slice capabilities and requirements, middleware DSL metadata,
  agent/slice categories, tags and versions, inactive command/strategy telemetry,
  and helpers without runtime consumers. Middleware remains a plain behaviour.

- Replace repeated-check test helpers with subscriptions, process monitors and
  lifecycle events, including AgentServer readiness telemetry. Document completion
  waits through `AgentServer.call_until/5`.

- Rewrite task-number references and migration commentary in source documentation
  and test descriptions to describe current behavior.

- Replace references to deleted design documents in comments, module docs and
  test descriptions with self-contained explanations of the current contracts.

- Add development-only Benchee benchmarking through `mix bench`, with native
  Ash reducer and conversation token-estimate suites and a quick smoke mode.

- Remove the unused sensor abstraction, runtime, DSL, generator and fixtures,
  including sensor subscription declarations on slices. Use agents, slices,
  directives and schedules for event-producing capabilities.

- Remove generated runtime wrappers and private configuration accessors from
  instance modules. Keep supervision entry points on the Spark host, read DSL
  configuration through `Aikido.Dsl.Instance.Info`, and use `Aikido.config/2`
  plus the shared lifecycle, persistence and debug APIs.

- Move emitted signal ID/time generation into directive execution. Make identity,
  memory and thread reducers derive timestamps and IDs from their inputs, and
  remove sleeping and mutable counters from reducer test fixtures. Add replay
  and effect-boundary regression coverage.

- Clarify throughout the architecture documentation that agent and slice actions
  are pure: all side effects belong in directives.

- Cache ReAct token estimates in slice state and increment them as messages are
  appended. Refresh estimates on history replacement, handoff and restore, and
  clear provider counts belonging to the replaced context.

- Replace automatic lossy context trimming with Makewright-style model-written
  handoffs at clean ReAct boundaries. Preserve system instructions, queued
  messages, run scope, todos and prepared tools across takeover. Keep original
  context on failed handoffs; remove pruning/sliding options and pipeline.

- Add an explicit ReAct `:setup` state before model execution. Queue messages
  and deliveries into the first model request, support setup cancellation and
  bounded preparation, and treat restored setup runs as interrupted.

- Prepare native Ash AI tools once per ReAct run and reuse their descriptions
  and registry across model turns, parallel calls and retries. Exclude generated
  callbacks from snapshots and rebuild them for new runs after restoration.

- Accept native Ash AI tool names and source configuration. Build execution
  registries internally instead of persisting generated functions. Remove the
  custom tool adapter, per-tool callback-pair input and example callback wrappers.
  Preserve configured Lua context and tool configuration across team delegation.

- Use native Ash scope extraction for tool-result signals, including Ash's shared
  context propagation rules.

- Apply agent and slice codecs to initial and runtime durable snapshots; retain
  boot identifiers and explicit runtime configuration outside their output. Carry Ash actor/tenant context
  through command signals and follow-up effects without persisting caller scope.

- Retain ReAct history, queue messages, stream text/thinking and record usage.
  Add bounded cancellable model/tool execution, opt-in retries, context handoff,
  idle handoff, and explicit interrupted-run recovery.
- Add the optional Todo slice and todo-gated completion, plus an offline LiveView
  example for conversations, streaming and todo evidence.
- Activate lazy workers on delegation, queue worker tasks, deliver results to an
  orchestrator, and handle task deadlines, member loss and interrupted work.

- Update Ash AI to 1.3 in the library and example app, making upstream tool
  search, tool-call approval, and revised chat storage APIs available.

- Remove component discovery, startup scanning, public catalog delegates, and
  their tests. Remove legacy action metadata and the unused compensation engine.
- Consolidate runtime errors in `Aikido.Error`; preserve native Ash errors and
  use the same retry classification across execution paths.
- Start supervised agents and spawned children through DurableServer. Remove
  the runtime relationship store and optional non-durable instance path; save
  current parent bindings in snapshots, including adoption and detachment.
- Make the remaining agent, slice, and sensor DSL hosts native Ash resources.
  State schemas become attributes and slice configuration uses native action
  arguments. Remove generated contract modules and the custom schema facade.

- Remove no-op execution validators and obsolete action output-schema plumbing;
  native Ash action inputs and return types own those checks. Use native atom
  and enum constraints for child-bus names and child restart policies.

- Build native action tools directly with `AshAi.Tools`; remove the custom
  action schema/JSON Schema and tool-casting facades. Ash AI owns argument
  validation and result serialization, including its `input` argument envelope.

- Generate directive `t()` types once in the Spark host instead of maintaining
  handwritten struct types in each directive module.

- Configure agent snapshot retention with `persistence :permanent | :temporary`.
  Temporary agents delete their saved state on stop; permanent agents retain it.
  Add a generic `delete` action and generated domain interface for removing a
  running or stopped agent's saved state explicitly.

- Define directives with the Spark `Aikido.Directive` host, reusing Ash typed
  structs and requiring an `exec/3` behaviour callback on the directive module.
  Replace protocol implementations with callbacks on the built-in directives;
  validate their modules with Ash/Spark's behaviour constraint.

- Use Ash’s native `:union` arguments for thread entries and memory space
  defaults; remove the custom union type.

- Make FSM a native `Aikido.Ash.Slice` resource that owns its `:transition`
  action; keep `FSM.Transition` solely as the Ash action implementation.
- Move production and example generic-action callbacks into dedicated
  `Ash.Resource.Actions.Implementation` modules; remove legacy reducer wrappers
  and show implementation sources alongside the runnable examples.
- Declare the built-in children query on a shared runtime resource and implement
  it with `Ash.Resource.Actions.Implementation`, preserving domain state.
- Replace the custom action DSL with native Ash generic actions and a shared
  `Aikido.Types.ActionResult` contract that validates returned directives. Agents may
  declare reducers directly; built-in slices and the example app use native
  resource/action targets.
- Initialize and validate agent state through native Ash resource attributes
  and typed-struct contracts, with regression coverage for defaults, constraints,
  native tool schemas, and state projection.

### Added

- Experiment with generic Lua hook request/response: `aikido.request` waits in
  the hook task for an application-supplied callback to return a response.
  Keep UI delivery, waiting and cancellation in the application; add no core
  request service, agent actions or interaction state.
  Add a standalone LiveView example for answering requests, reconnecting,
  denying tool execution in Lua, and cancellation. No approval-specific hook
  decision or UI dependency is added to the core.

- Add bounded Lua lifecycle hooks to ReAct agents and teams. Ordered synchronous
  gates return typed decisions; asynchronous observers can send signals and
  inject context into later model requests. Add an offline LiveView hooks example.

- Add `Aikido.AgentServer.call_until/5` for subscribe-before-dispatch command
  completion, including timeout, process monitoring, and subscription cleanup.

### Removed

- Remove unused action namespace modules and empty test-support namespace stubs.

- Remove historical ADRs, research, task plans, legacy guides/Livebooks, review
  notes, migrations, and stale generated DSL references. Retain current guides
  and refresh the README and ExDoc navigation for the Ash/DurableServer API.

- Remove the `Jido.Ash.Agent` data-layer behaviour. Register it as a resource
  extension; generic agent/team actions no longer occupy the data-layer slot.

- Remove the legacy pod slice, topology, and mutation runtime; use Ash teams.

- Remove agent client attachment tracking, `AgentServer.attach/detach/touch`, and
  automatic idle shutdown. Managed agents now stop explicitly; storage-backed
  restoration remains available.

### Features

- Establish Aikido as an independent project in `barnabasJ/aikido`. Rename the
  application, owned modules, configuration, runtime signals, Mix tasks, tests,
  and examples from Jido to Aikido. Continue using the external `jido_signal`
  dependency under its original namespace.

- Accept `topology` in team start actions, including nested team graphs through
  member initial state. Validate root graphs before activation, preserve DSL
  defaults when omitted, and retain saved graphs on durable restoration.

- Name generated domain interfaces `<agent>_<action>` so each agent's lifecycle
  and signal actions group together, including bang variants.

- Require agent signal targets as the third positional argument. Inherit routed
  public actions from embedded Ash slices without duplicate agent declarations;
  retain private and schedule-only actions internally.

- Replace public agent/team CRUD actions with generic start, signal, inspect,
  list and stop actions. Commands accept IDs, PIDs or references and return
  compact receipts. Inspect state explicitly; configure running topologies with
  `configure_topology`. Migrate the playground, AI tools and recovery tests.

- Replace InstanceManager with DurableServer and its native EKV/object-storage
  backends. Default Jido agents now use durable keyed activation and strict
  callback synchronization; restore team topology and logical cron specs after
  failure. Preserve agent and slice serialization callbacks. Require Elixir 1.19.

- Expose example agent/team spawning, delegation, roster, stop, and removal
  through AshLua. Carry trusted agent/resource and managing-team context into
  native Ash AI callbacks; demonstrate AI workers spawning helpers through Lua.
- Generate Ash signal action arguments from their routed action contracts,
  including mounted slices, preserving native types, defaults, and constraints.
  Remove duplicate signal action declarations from the example agents.
- Standardize data DSLs on `schema do` and native Ash attribute declarations,
  including action input/output, slice state/config, and sensor schemas. Compile
  action inputs directly into Ash typed structs on the action module; use nested
  contracts for other plain hosts and reuse existing Ash
  agent and slice resources. Preserve native Ash/Splode validation errors.
- Add a nested-team playground with fixed subteams, dynamically spawned squads,
  recursive topology visuals, message delivery, and subtree removal.
- Reuse Spark.InfoGenerator for DSL options and AshAI for tool schemas and Ash
  action execution. Ash resource/action tools use AshAI's `input` envelope and
  support create/read/update/destroy actions as well as generic actions.
- Complete team lifecycle actions through a one-shot subscription registered
  before the command starts; remove the separate late `Team.await` helper.

- Use ReqLLM by default in AI example resources, allowing creation with just
  a model and tools. Select the scripted client explicitly in offline demos,
  playground mode, and tests.

- Expose system-prompt and iteration-limit overrides in AI playground creation
  forms, and verify model/client/prompt/iteration configuration through the
  common public agent and team create interfaces.

- Show exact agent, slice, action, directive, and supporting source definitions
  on every example page, one independent accordion per definition. Agent and
  slice panels start open, others closed, and live updates preserve toggles.

- Add a Phoenix LiveView playground to the example app, with one page per
  example, descriptions and workflow/state visuals, browser-scoped runs,
  live signal and topology updates, offline/live AI selection, and lifecycle
  controls. Start it with `mix phx.server`; no Node build is required.

- Add a common Ash AI interface for agents and teams with runtime tool lists,
  contextual Ash AI callbacks, and inherited member configuration. Add an
  orchestrator example with fixed and dynamic workers, worker-created helpers,
  real Ash AI/AshLua tools, an offline demo, and a z.ai entry point.

- Default agent resources to the `Jido.Default` runtime, started by adding `Jido`
  to a supervision tree. Transform `agent.schema do` Ash attribute declarations
  into real resource attributes, deriving runtime state contracts at compile time.
  Initial values and snapshots now use ordinary fields such as `count` rather
  than a public `state` map.

- Add a runnable Ash agent example application with a generated domain interface,
  five agent resources, embedded slices, asynchronous work, teams, and tests.
- Configure Spark formatting to remove DSL parentheses and use native Ash
  TypedStruct blocks for longer contracts. Live Ash reads skip registry entries
  whose processes have already terminated.
- Generate and export the complete DSL formatter arities with `mix spark.formatter`,
  and include the example app in root formatting checks.
- Remove legacy schema translation and automatic option-contract conversion;
  declare Ash data fields directly and Spark DSL sections explicitly.
- Add Ash domain interfaces for process-backed agent resources, embedded slice
  resources with routed Ash actions, and team resources with member lifecycle
  and signal delivery. Existing runtime and pure action/directive contracts are
  preserved. See `guides/ash-integration.md`.
- Standardize data contracts and runtime structs on Ash types and DSL options
  on Spark validation. Remove direct Zoi and NimbleOptions dependencies, update
  generators and tool JSON schemas, and preserve defaults and state ownership.
- Stabilize the existing AI fire-and-forget test by awaiting completion before
  verifying its background task's mock.


## [v2.2.0](https://github.com/agentjido/jido/compare/v2.1.0...v2.2.0) (2026-03-29)




### Features:

* add partitioned multi-tenancy support (#218) by mikehostetler

* rebuild multi-tenancy around partitioned pods by mikehostetler

* reduce default log verbosity (#219) by dl-alexandre

* add first-class orphan lifecycle and adoption (#213) by mikehostetler

* add first-class orphan lifecycle and adoption (#212) by mikehostetler

* add first-class orphan lifecycle and adoption by mikehostetler

### Bug Fixes:

* remove invalid doctest-style doc examples (#227) by mikehostetler

* reject instance manager lifecycle opts in SpawnAgent (#222) by mikehostetler

* reject instance manager lifecycle opts in SpawnAgent by mikehostetler

* reduce default log verbosity (noisy logs) by dl-alexandre

* align action logging with instance config (#217) by mikehostetler

* observability: align action logging with instance config by mikehostetler

* observability: align action telemetry with log args by mikehostetler

* agent_server: always wrap parent-down reason as {:shutdown, _} by mikehostetler

* thread: handle missing thread in filter_by_kind (#211) by Julian Scheid

* thread: handle missing thread in filter_by_kind by Julian Scheid

* thread: tighten filter_by_kind guards by Julian Scheid

* agent_server: always wrap parent-down reason as {:shutdown, _} (#207) by Julian Scheid

* pass details as keyword to execution_error (#206) by Julian Scheid

* pass details as keyword to execution_error by Julian Scheid

* preserve execution error details compatibly by Julian Scheid

* agent: correct plugin_schedules typespec (#204) by CptnKirk

* restore git_ops changelog marker placement by mikehostetler

### Refactoring:

* formalize pod extraction seams (#233) by mikehostetler

* harden SpawnAgent directive validation by mikehostetler

* agent: pass jido instance via strategy context by mikehostetler

* harden runtime store ownership and stress adoption by mikehostetler

## [v2.1.0](https://github.com/agentjido/jido/compare/v2.0.0...v2.1.0) (2026-03-14)

### Features:

* scheduler: durable in-house cron scheduler for Jido 2.1 (#181) by mikehostetler

* scheduler: in-house cron engine with durable instance replay by mikehostetler

* plugin: support static subscriptions and fix documentation (#198) by Iulian Costan

* plugin: support static subscriptions and fix documentation by Iulian Costan

* storage: add Redis storage adapter (#184) by austin macciola

* storage: add Redis storage adapter by austin macciola

### Bug Fixes:

* ci: resolve lint guard and dialyzer issues by mikehostetler

* finalize durable scheduler hardening and dialyzer cleanup by mikehostetler

* scheduler: harden durable cron replay and callbacks by mikehostetler

* scheduler: restore cron replay invariants by mikehostetler

* misplaced end in example (#201) by Jan Pieper

* sensor: resolve via refs for subscription signals (#200) by mikehostetler

* storage: harden redis adapter and instance integration by austin macciola

* Improve typespec precision (#196) by Philip Munksgaard

* preserve plugin spec structs in agents (#188) by mikehostetler

* normalize StopChild shutdown reasons by mikehostetler

* align StopChild with SpawnAgent restart semantics by mikehostetler

* util: use Code.ensure_compiled to resolve action validation ordeâ¦ (#183) by caike

* util: use Code.ensure_compiled to resolve action validation ordering by caike

* error: make Jido.Error splode conversions reliable by Pascal Charbonneau

* observe: harden sync and async tracer span semantics (#178) by mikehostetler

* observe: harden tracer sync and async span semantics by mikehostetler

* observe: prevent cross-process scoped callback re-execution by mikehostetler

### Refactoring:

* scheduler: simplify runtime registration by mikehostetler

## 2.0.0 - 2026-02-22

### Changed
- Promote `2.0.0-rc.5` to stable `2.0.0`
- Require Elixir `~> 1.18`
- Bump ecosystem deps to stable ranges: `jido_action ~> 2.0`, `jido_signal ~> 2.0`

### Fixed
- Restore compile-time `signal_routes` behavior while preserving callback compatibility (#170)
- Prevent loopback `emit` from redispatching to the current agent in AgentServer (#171)

### Tooling
- Align Igniter setup/docs with the instance-scoped API

## 2.0.0-rc.5 - 2026-02-16

### Added
- Observability V2: per-instance debug & telemetry configuration (#129)
- Always-on `emit_event` helper for lifecycle observability (#141)
- Event contracts and lifecycle observability docs (#140)
- Directive struct included in agent_server telemetry metadata (#134, #142)
- `RunInstruction` directive and pure FSM cmd (#139)
- Prevent synchronous signal-call blocking in AgentServer (#150)
- Declarative schedules DSL for cron (#137)

### Changed
- **BREAKING**: Unify persistence on `Jido.Persist` and `Jido.Storage` (#156)
- Centralize defaults and validate observability config
- Harden InstanceManager registry and key semantics (#156)
- Share instruction tracking helpers in strategy layer (#166)
- Use shared templates in Igniter generator tasks (#165)
- Unify entry normalization across storage adapters (#164)
- Extract shared signal collector test helper (#167)

### Fixed
- Normalize timeout diagnostics in `await_all`/`await_any` (#168)
- Cancel timed-out completion waiters in AgentServer (#162)
- Preserve file read errors during append (#163)
- Return normalized errors for corrupt entry logs (#161)
- Avoid atom creation from persisted journal kinds (#160)
- Restore agent metadata export for discovery (#159)
- Return routing error struct for unknown signals (#155)
- Normalize refinement errors for Zoi validation in plugins
- Make ETS `append_thread` atomic and revision-safe (#150)
- Send `jido.agent.stop` when stopping child (#138)
- Normalize id in both constructor paths to guarantee UUID7 (#132)
- Fix silent cron tick failure (#137)
- Normalize util and storage-facing error contracts (#153)
- Offload runtime dispatch from sensor process (#152)

### Dependencies
- Bump `jido_action` and `jido_signal` to 2.0.0-rc.5

---

## 2.0.0-rc.4 - 2026-02-06

### Added
- Memory plugin: implement `Jido.Memory` as default plugin under `__memory__` key (#125)
- Identity plugin: add `Jido.Identity` as default agent plugin (#126)
- Plugin singleton flag in plugin config schema (#120)
- Plugin signal middleware improvements (#123)

### Changed
- Update `signal_routes` to accept context parameter (#121)

### Fixed
- Wire `on_restore/2` into generated `restore/2` callback (#122)

### Tests & Chores
- Add memory plugin and default plugins persistence examples (#127)
- Organize example tests into subdirectories (#124)
- Add `Jido.Plugin` to doctor ignore_modules for macro-generated defs
- Remove AI cruft and build artifacts

### Dependencies
- Bump `jido_action` and `jido_signal` to 2.0.0-rc.4

---

## 2.0.0-rc.3 - 2026-02-04

### Added
- `cmd/3` to support per-action timeout opts (#117)
- Unified persistence layer for agent checkpoints and thread journals (#110)
- Telemetry infrastructure with span tracking and metrics (#109)
- Debug helpers and improved timeout errors (#111)

### Changed
- **BREAKING**: Renamed `Jido.Skill` to `Jido.Plugin` (#115)

### Fixed
- Dialyzer/Credo: add :mix to PLT, remove unnecessary ignores (#118)

### Dependencies
- Bump `jido_action` and `jido_signal` to 2.0.0-rc.3
- Bump `ex_doc` from 0.40.0 to 0.40.1 (#112)

---

## 2.0.0-rc.2 - 2025-01-30

### Changed
- **Zoi Schema Migration**: Convert remaining structs to use Zoi schemas for consistent validation (#106)
- **Macro Decomposition**: Decompose large macros and improve code organization (#101)
- **Sensor Simplification**: Simplify `handle_event/2` to directive-only format (#108)

### Fixed
- Address code quality issues from codebase review (#107)
- Improve process lifecycle handling and test reliability (#100)

### Dependencies
- Bump `jido_action` and `jido_signal` to 2.0.0-rc.2

---

## 2.0.0 (Architecture Preview Notes) - 2025-12-31

### Added
- **Instance-Scoped Supervisors**: Jido now uses user-owned, instance-scoped supervisors instead of auto-started global singletons
- **Jido Supervisor Module**: New `Jido` module acts as a Supervisor managing per-instance Registry, TaskSupervisor, and AgentSupervisor
- **Agent Lifecycle API**: New functions `Jido.start_agent/3`, `Jido.stop_agent/2`, `Jido.whereis/2`, `Jido.list_agents/1`
- **Test Isolation**: New `JidoTest.Case` module for automatic test isolation with unique Jido instances
- **Per-Instance Scheduler**: Scheduler can now be scoped to a Jido instance
- **Multi-Agent Coordination**: New `Jido.await/3` and `Jido.await_child/4` for coordinating agent completion
- **Discovery Delegates**: Discovery functions accessible via main Jido module

### Breaking Changes
- **Explicit Supervision**: Users must now add `{Jido, name: MyApp.Jido}` to their supervision tree
- **Agent Start**: Use `Jido.start_agent(instance, agent, opts)` instead of `AgentServer.start/1`
- **Instance Option**: Pass `jido: MyApp.Jido` option when starting agents directly

### Changed
- Refactored from global singletons to instance-scoped architecture
- Agents now register in instance-specific Registry
- TaskSupervisor and AgentSupervisor are per-instance
- Updated all examples to use new 2.0 patterns

### Migration from 1.x
See the Migration section in README.md for upgrade instructions.

---

## Unreleased - 2025-08-29

### Added
- **Modular API Architecture**: Refactored monolithic `Jido.ex` module into specialized modules:
  - `Jido.Agent.Lifecycle` - Agent lifecycle management (start, stop, restart, clone operations)
  - `Jido.Agent.Interaction` - Agent communication (signals, instructions, requests)
  - `Jido.Agent.Utilities` - Helper functions (via/2, resolve_pid/1, generate_id/0, log_level/2)
- **Comprehensive Test Helpers**: New `JidoTest.Support` module with common test utilities:
  - Registry management helpers (`start_registry!/0`)
  - Agent lifecycle helpers (`start_basic_agent!/1`, automatic cleanup)
  - Signal and state assertion helpers
  - Consistent test patterns across all modules
- **Table-Driven Test Coverage**: Implemented data-driven delegation tests for maintainable 100% API coverage
- **Performance-Optimized Test Suite**: Consolidated and streamlined tests with `@tag :slow` for optional performance tests

### Breaking Changes
- **None**: All public API functions remain fully backward compatible through delegation in main `Jido` module

### Changed
- **Improved Test Performance**: ~40% reduction in test execution time through:
  - Elimination of redundant test cases
  - Reduced UUID generation from thousands to ~110 total
  - Parameterized test scenarios instead of copy-paste patterns
  - Common setup helpers reducing boilerplate
- **Enhanced Test Maintainability**: 
  - Centralized test helpers eliminate code duplication
  - Table-driven tests make adding new API methods trivial
  - Consistent patterns across all test files
- **Better Resource Management**: Automatic test cleanup prevents resource leaks and test isolation issues

### Fixed
- **Test Suite Optimization**: Removed redundant tests while maintaining high coverage (68.4% overall, >80% for key modules)
- **Code Quality**: Addressed Credo warnings in test files (replaced `length/1` with `Enum.empty?/1`)

---

## Previous - 2025-08-25

### Added
- **Automatic Action Registration**: Skills can now declare required actions in their configuration using the `actions` field, which are automatically registered when the skill is mounted
- **Module Path Refactoring**: Moved action modules from `Jido.Actions.*` to `Jido.Tools.*` namespace for better alignment with `jido_action` library
- **Default Skills**: Agent server now uses default skills (`Jido.Skills.Basic` and `Jido.Skills.StateManager`) instead of hardcoded actions

### Breaking Changes
- **Action module paths**: All action modules moved from `Jido.Actions.*` to `Jido.Tools.*` to align with the `jido_action` library
- **Runner system removed**: The separate `Jido.Runner.Simple` and `Jido.Runner.Chain` modules have been deprecated. Agents now use built-in execution logic that processes one instruction at a time (equivalent to the former Simple Runner behavior)

### Changed
- **Skill configuration**: Skills can now declare required actions using the `actions` field for automatic registration
- **Agent options**: Both `actions:` and `skills:` options are supported, with skills providing the preferred declarative approach

### Fixed
- Task update action now only updates provided fields instead of overwriting with nil values
- State manager update action now uses `:update` operation instead of `:set` for proper semantic behavior
- Improved error handling for action registration failures

## 1.1.0-rc.1 - 2025-02-18

- Address open Credo Errors
- Add documentation
- Clean up README in prep for 1.1 release

## 1.1.0-rc - 2025-02-08

- Stateful Agents
