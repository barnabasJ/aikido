# Changelog

## Unreleased

- Prepare tracked member stops under the exact receiving activation's authority.
  Require successful native cleanup and its verified clean process exit before
  completing the topology operation. Reject cleanup without terminating the
  member, preserve public stop caller policies, and retain exact targets when
  a proposed topology removes their declarations.

- Wait for receiver-owned saved topology reconciliation when starting restored
  teams, including nested members. Restoration failures retain the existing
  identity for inspection instead of applying fresh-start cleanup.

- Bind fresh nested team initialization and correlated failed-start cleanup to
  the receiving activation's native authority. Preserve normal public caller
  authorization and saved topology on restoration.

- Restore physically older mounted records returned by opaque checkpoint
  callbacks through native create actions after authentication. Preserve saved
  field values and explicit nils while applying defaults to newly declared
  fields; no claim is made about presence lost by an earlier typed decode.

- Accept permanent sink failures whose optional retry hint is omitted, through
  both native settlement commands and direct typed signals.

- Add explicit `reconcile_inherit` Team configuration and tracked
  `reconcile_inherited` commands. Running nested members acknowledge opted-in
  nonidentity fields under their own native authority; creation overrides remain
  authoritative, receiver casts validate values, and failures/timeouts remain
  observable instead of reporting completion early.

- Require runtime-correlated self delivery and an active writing credit before
  journal Work reaches an application action. Direct typed Work cannot start
  database work, including when it copies an existing batch range.

- Add opt-in bounded sink retries to journal consumers. Application-classified
  transient failures may provide a retry delay; persisted attempt counts survive
  restart and stale timer deliveries do not reset the budget. Success or an
  explicit manual retry resets the count. Default retry limit remains zero.

- Add a public Team roster replay configuration command for retained identities
  whose membership journal was disabled. Native adoption creates the embedded
  journal; authorized Follow bootstraps current topology without fake history.

- Add native retained-thread replay configuration preserving existing entry
  identity and sequence. Confirm source metadata with replay batches for
  application routing as data, preserving application authorization boundaries.

- Add explicit consumer journal drain and resume commands. Drain confirms fresh
  live source heads and application commits before pausing; offline sources,
  replay gaps and sink failures report a blocked drain instead of success.

- Add transient per-call attempt timing for deterministic model I/O deadlines,
  progress windows and retry backoff. Production keeps System/Process defaults;
  clock capabilities never become persisted AI configuration.

- Add optional Thread replay with explicit source opt-in, immutable entry
  receipts, bounded consumer demand and a native save boundary before Batch
  publication. Correlated replies retain consumer authority and reject forged
  private typed ingress. Ordinary Thread appends avoid replay receipt work.

- Allow AsyncTask work processes to retire with their originating agent using
  `cancel_on_owner_exit?: true`; external services retain their own transaction
  and cancellation semantics.

- Require distinct explicit public command names for unrelated mounted route
  targets. Retain alternate spellings and predicates during owner admission so
  no-op reducers still check the correct public policy. See `guides/thread-replay.md`.

- Bind authenticated durable activations to their execution scope. Correlated
  team and ownership messages preserve the recipient's authority, while public
  commands keep caller authorization. Changing AI execution identity requires
  a restart and reports an actionable typed forbidden error.

- Generate an authorized `execution_identity_matches` command that checks the
  caller's actor and tenant against the activation binding without exposing
  private scope or credentials. Unbound activations return false.

- Retain accepted AI delivery request IDs across runs and checkpoints to avoid
  appending duplicate incoming text or starting a duplicate model run. Caller
  authorization remains required before duplicate suppression.

- Notification publication topics support native Ash alternatives and the
  `:_signal` placeholder for the triggering signal type. Subscribers can select
  a concrete topic template for agent-wide or signal-specific typed delivery.

- Omit normally retiring agents from native list results when their final exit
  uses DurableServer's shutdown tuple. Keep timeouts and unexpected crashes as
  typed runtime errors.

- Align the offline research-team and command-line demonstrations with dynamic
  squads, nested teams and worker-owned helpers. Reuse existing squads on later
  tasks, match the live CLI deadline to the playground, and document persistent
  browser credentials. Verify example flows through real browser interactions.

- Encode and decode the snapshot resource identifier through native Ash atom
  types, retaining rejection of unknown resource atoms.

- Make EKV optional for library consumers. The example app directly selects the
  reviewable EKV cleanup fork while its periodic maintenance optimization is
  evaluated. Other applications can select released EKV or another backend.

- Register the background-evidence team and worker in the example domain, making
  their native lifecycle and signal actions available to the complete demo suite.

- Isolate playground node heartbeats in a native EKV store so agent snapshot
  traffic cannot queue ahead of liveness writes. Keep watchdog deadlines unchanged
  and record heartbeat latency and age in the scale benchmark.

- Skip native inspector action recording unless an attachment or subscription
  requests it; display-only playground subscriptions opt out. Add bounded
  signal-throughput and approximate median/p95 duration graphs to the dashboard.

- Add playground inspector capture controls that detach expensive state/event
  projection while keeping recorded history and normal example updates available.
  Preserve the setting across example restarts and add spacing to empty history.

- Coalesce queued playground tree and inspector refreshes so large runs do not
  replay a stale display backlog. Retain completion timing independently of the
  browser, and add a staged scale/storage benchmark verifying 50,000 agents.

- Reduce inspector capture work for empty and untyped maps and measure JSON size
  without flattening the encoded value. Keep native sensitive-field redaction and
  exact known credential keys, replacing heuristic credential-name regex checks.


- Bound AI attempt preflight registration and the following owner-state read by
  one monotonic window, clamped to any absolute deadline. Report preflight budget
  expiry as timeout. Preserve relative per-attempt retry/work windows, the public
  subscription default and asynchronous unsubscribe behavior.

- Deliver terminal task results without a top-level inherited deadline. Preserve
  the original deadline inside task correlation metadata while allowing an idle
  receiver to start under its own execution policy. Existing active runs retain
  their current deadline.

- Give the AI attempt's subscribe handshake the attempt's remaining deadline.
  `Aikido.AiReact.CancellableTask` opens every attempt with a synchronous
  subscribe into the owning agent's mailbox, so a saturated owner queue could
  expire the 5 s default call budget before the tool's own budget ran and fail
  the attempt with `{:error, {:owner_unavailable, {:timeout, ...}}}`. The
  handshake now carries the attempt's remaining tool deadline, and
  `AgentServer.subscribe/4` accepts an optional `:timeout` that bounds the
  registration call. The default stays 5 s where no budget is given.

- Keep unknown failed-task details out of parent-model message text while
  retaining raw task results and notification metadata for internal consumers.
  Preserve authored error guidance and add a fixed missing-model recovery
  description.

- Preserve typed topology failures and runtime-loss causes through generated
  team commands. Unknown operation failures retain their original reason behind
  safe native error projections; recognized validation and timeout messages are
  unchanged.

- Return a native structured runtime-unavailable error from external commands,
  preserving exit causes while omitting private request data from error displays
  and AI/Lua tool projections. Missing agent identities use the same error type.

- Log a bounded, payload-free tool-runtime diagnostic with the existing tool
  name and reference at error level. Preserve the opaque model-facing error
  envelope and original internal error. Report fixed kinds, recognized
  structural codes and exception modules; include argument-free runtime frames
  only when available. Omit arbitrary messages, private causes, arguments and
  source paths.

- Preserve durable scope refusals as native typed forbidden errors through the
  generated public start action. Expose only the operation and an atom refusal
  reason, replacing opaque reasons with a generic code and excluding the
  original startup stack or authority data. Direct durable activation errors
  retain their existing transport shape.

- Remove recursive bootstrap schema and callback traversal. Use flat native Ash
  map projection and safe term transport before the claim, with native state
  initialization afterward. Paired owner codecs may distinguish fresh input from
  snapshots through `reinstate/2`. Hook state contains Lua scripts and serializable
  settings only; application interactions use the scoped AshLua surface. Preserve credential-safe codec
  failures without raw fallbacks and native omitted/nil behavior. Initialized
  snapshots remain supported; unfinished envelopes with retired generic callback
  bookkeeping reject explicitly with a saved-identity reset instruction.
- Remove per-hook Elixir request callbacks and callback serialization. Expose the
  request/response example's approval as a scoped native application action called
  from Lua. Persist hook source and serializable settings through normal Ash types.

- Add opt-in `todo_continuation: :nudge_once`: remind once about unchanged open
  blocking work, then report a typed `CompletedUnclosed` error on a consecutive
  idle final answer. Actual tool dispatch and newly consumed messages reset the
  idle window. Relevant delegated work and activation hold todo completion until
  results arrive. Existing deadline and continuation budgets still apply.
- Allow native todo verifiers to return `Aikido.AiReact.TodoVerification` with
  corrective feedback and sensitive per-run opaque data. Legacy boolean verdicts
  remain supported; optional native `:data` arguments receive the prior value.
  Correlated verdicts alone adopt data; new runs and restoration clear it.
  Verifier action context includes the actual receiving agent's runtime identity
  without replacing native actor or tenant authority. The verified-assistant
  example demonstrates typed feedback, continuation data and bounded reminders.

- Restore durable caller authority through an application-owned scope adapter
  and opaque revocable credentials. Use unchanged DurableServer claim/init
  callbacks; fresh native initialization runs after the claim and saved agents
  bypass it. Apply paired path codecs before the first bootstrap write and
  retain only their transformed paths for decoding after authentication.
  Identity rebinds can adopt replacement credentials in the same native action
  as their identity changes. Validate saved identity against the actual claim;
  preserve custom native scope protocols and fresh Todo defaults without
  applying saved-run interruption. Reject unsafe checkpoint-only bootstrap input
  instead of persisting a fallback. Restore saved identities in anonymous pools
  without requiring a fresh agent module or fresh attributes. Owning codecs use
  native Ash types for serialization; state validation stays in native
  initialization after the claim.

- Preserve topology startup and cleanup failures in a native typed error with
  the stable agent ID, instead of a generic unknown error. Forward the current
  caller's scope through explicit stops, team member cleanup and startup
  rollback.

- Require Ash 3.37.2 or later within 3.x for native calculated publication
  contracts.

- Add opt-in agent publications and subscriptions backed by native Ash PubSub,
  typed signals generated from explicit root and slice calculations,
  receiver-owned scope, lifecycle subscription cleanup, and a playground
  counter/observer example.

- Add sparse `ActionResult.changes` for mounted reducer attributes. Apply
  results through a real private native update, retaining the existing `state`
  input for compatibility. Collect native notifications until all routed updates
  succeed, then schedule publication after state adoption, ahead of reducer
  effects.

- Warn on the third completed successful cycle for periods one through four,
  using the existing bounded history and retaining configured terminal limits.
  Attach native typed run/turn/period metadata to the model warning so journals
  can project system notes without matching text. Period-one warnings move from
  the second identical batch to the third.

- Allow a pure MFA to select completed tool-batch comparison keys while
  retaining native bounded cycle detection, result adoption and exact
  comparisons by default. Fail explicitly when a configured comparison callback
  fails.

- Add opt-in bounded context-summary regeneration for empty, invalid or
  oversized handoff documents, retaining history and usage with fresh result
  correlation. Truncated summaries remain terminal; provider retries keep their
  existing policy.

- Fail an AI run at its configured turn limit when the last model response still
  requests executable tools. Retain the response history and usage, execute no
  further tools, and accept a genuine final answer at the limit.

- Run the existing synchronous before-model hooks when incoming text resumes a
  waiting AI run. Check the handoff budget after adopting delivered text and
  hook context, while retaining the run's request, deadline, caller and prepared
  tools.

- Validate configured AI clients after compilation through Spark and native Ash
  module casting. Materialize the default lazily and reject explicit nil without
  forcing consumer modules to compile a sibling client early.
- Change successful tool-loop fingerprints to include returned content alongside
  each call's name and arguments. This intentionally changes the previous
  input-only behavior: the same call with different output no longer adds a
  repeat warning or advances the cycle limit. Fresh call IDs and result arrival
  order do not change a batch fingerprint.
- Keep successful-cycle history and the prior signature unchanged after failed
  or mixed batches. Continue to count those batches under the independent
  consecutive-error limit.
- Cover the existing timeout-completion envelope and rejection of a late result
  for a completed call while a distinct next call is pending in the same
  request.
