# Teams

A team is an Ash agent resource with `Aikido.Team.Extension`. It can run its own
actions and AI turns while managing named agents and nested teams through the
same Ash domain interface.

```elixir
defmodule MyApp.ResearchTeam do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension, Aikido.AI.Extension]

  agent do
    name "research_team"
  end

  team do
    member :analyst, MyApp.Analyst
    member :reviewer, MyApp.Reviewer, activation: :lazy, depends_on: [:analyst]
    worker :researcher, MyApp.Researcher, max_members: 8
    worker :squad, MyApp.ResearchSquad, max_members: 2
  end
end
```

Creation starts eager members in dependency order. `ensure_member` activates a
lazy member; `add_member` creates an agent or team from a worker template.
Dynamic names are strings and never become atoms. `owner` records hierarchy;
`depends_on` determines activation and shutdown order. Removing an owner removes
its descendants. Dependencies require an explicit cascade when removing them.
`stop_member` preserves the desired entry; `remove_member` removes it.

`send`, `broadcast`, and `assign_task` route work through signals. Team and
agent resources share the domain interface. AI agents receive dynamic tools at
creation; AshAI and AshLua can expose the team's management actions as tools.
The research team example demonstrates orchestrators, fixed workers, dynamically
spawned workers, workers spawning helpers, and nested teams.

The default Aikido runtime uses DurableServer. Team snapshots retain desired
topology; recovery rebuilds process membership and monitors, and reconciles
eager members. Agent and slice serialization callbacks remain supported. Local
EKV storage survives restarts when its disk remains available; configure a
shared DurableServer backend for machine failover. See
[runtime patterns](runtime-patterns.md).

Run `examples/agent_app` and visit `/examples/nested-teams` and
`/examples/research-team` for interactive trees and expandable source
definitions.

### Delegation and result delivery

`assign_task` activates a predefined lazy member before dispatching its work.
The optional `notify` argument names an orchestrator member, or `:self` for an
AI-equipped team. Terminal task results are delivered through
`ai.react.deliver`: an idle orchestrator starts a turn; an active one queues the
result. Set `metadata` to carry application-owned correlation data such as a
workflow step ID. The receiving AI run exposes structured task data in
`run_metadata.task`. Deliveries queued during an active run retain their
correlation data in `run_metadata.deliveries`.

Terminal result notifications omit the top-level `aikido_deadline_at` field so
an idle receiver does not adopt an expired task budget. The original deadline
remains nested in the task's metadata for correlation. Delivery into an active
or waiting run retains that run's existing deadline.

Failed-task message text uses recognized recovery descriptions or an authored
`AshAi.ToToolError` implementation. Unknown failures produce fixed guidance
rather than raw term inspection. The task ledger and notification metadata still
retain original results; this text projection does not sanitize the whole
envelope.

Generated public topology commands await their correlated lifecycle operation.
Native typed failures retain their class, runtime-loss failures use
`Aikido.Agent.Errors.RuntimeUnavailable`, and unknown operation failures use
`Aikido.Team.Errors.OperationFailed`. Their private `reason` fields preserve
causes; public displays and tool projections omit those fields. Existing
topology validation and timeout messages remain unchanged. Inspect the roster
before retrying: a failure or timeout does not establish whether a requested
member started or stopped.

AiWorker queues concurrent task deliveries and processes them in order. A team
tracks the task deadline (30 seconds by default); a timeout cancels queued or
active worker work and notifies the orchestrator. Duplicate or stale results
cannot deliver completion twice. A member crash fails its dispatched tasks and
ensures the desired member is running again, unless paused or removed.

On team restoration, previously dispatched/activating tasks fail explicitly with
`:interrupted`. Reconciliation delivers their configured notifications. External
effects are not replayed automatically. Applications can choose whether to retry
work after observing that outcome. Completion notifications are signal delivery,
not a durable exactly-once outbox guarantee.


## Member identities

A team root may use an application-selected ID such as `workflow/42`.
Member IDs follow ownership, not activation order: a top-level `:analyst` is
`workflow/42/analyst`; a `:helper` owned by that analyst is
`workflow/42/analyst/helper`. Names are escaped using
`Aikido.Agent.child_id/2`, so slashes inside a name remain one component.
`Aikido.Team.Topology.member_id/3` derives the same ID from a validated topology
without starting any processes. Restarting the same workflow can reuse that
identity; a new workflow execution needs its own root namespace.

### Foreground waits and background work

Team assignment always dispatches work asynchronously. Set `mode: :foreground`
and `requester` to the waiting member's topology key (or `:self` for the team
coordinator) when a caller waits for the result. The team rejects circular
foreground dependencies before dispatching work, including dependencies waiting
for lazy activation. Terminal and background tasks do not hold wait dependencies.
The guard covers the team's tracked dependencies; callers must identify their
requester and mode accurately. It cannot detect waits hidden in arbitrary code.

Set `mode: :background` to dispatch without holding a foreground dependency.
When a requester is supplied, its result is delivered later through
`ai.react.deliver`; an explicit `notify` overrides that destination. Existing
assignments without a requester retain their existing optional-notification behavior.

When a named AI requester needs the result delivered to its current run, pass
`requester_request_id` with that run's request ID. The team preserves this
correlation when a foreground task moves to the background, waits for activation,
or fails during activation or recovery. It is correlation, not permission: native
requester policies still apply, and the receiver accepts the result only for its
matching active run. Notifications to `:self` capture the coordinator's adopted
AI run instead of trusting a caller-supplied ID.

An accepted worker task can still fail before the inner AI request is adopted,
for example when the worker's model permission has been revoked. The worker
reports a classified, actionable task failure after confirmed native rejection.
Ambiguous transport failures retain the existing task deadline; they do not
claim that a request was rejected or that its effects never ran.

Call the team's generated `background_task` domain command with `task_id` to
release an existing foreground dependency. This changes neither the task identity
nor its worker, payload or deadline, and does not cancel the assignment. Subscribers
observe the mode change; a foreground waiter must return when it sees background
mode, then let the team deliver the eventual result. Repeating the command is
safe; settled tasks remain settled. Cancellation and timeout are separate operations.

The example's single Lua operation supports both modes:

```lua
-- Wait for a bounded answer (default).
return assert(agents.delegate({input = {member = "researcher", text = "Check the claim"}}))

-- Continue working; a correlated result arrives later.
return assert(agents.delegate({input = {member = "researcher", text = "Check the claim", mode = "background"}}))

-- Release an existing foreground wait without restarting its worker.
return assert(agents.delegate({input = {task_id = "existing-task-id", mode = "background"}}))
```

The research playground shows requester and mode for tracked tasks, with a
**Continue in background** button for active foreground delegations. Queue a
steering message to guide the orchestrator at its next model boundary. Background
results queue during an active run or open a new turn when the recipient is idle.

### Completing AI teams with background work

Set `options %{completion: :tasks}` in the team's `ai` block to hold a proposed
answer while background assignments notifying the team itself are pending.
Finished assignments arrive as `ai.react.deliver` signals and resume the waiting
conversation with its original request ID, deadline, iteration count and prepared
tools. The team's assigning parent receives a terminal result after synthesis,
not an interim "waiting for results" answer. Fire-and-forget work and assignments
requested by other members do not hold that team's answer.

## Reconciling opted-in inherited configuration

`inherit` copies own-state values at member creation. Retained members keep their
saved values unless the team explicitly opts fields into reconciliation:

```elixir
team do
  inherit [:storage_id, :storage_replay?]
  reconcile_inherit [:storage_id, :storage_replay?]
end
```

Update the parent's own values through an ordinary routed application action,
then call its generated `reconcile_inherited` command. Aikido tracks each current
member's acknowledgement, including opted-in nested teams, before completing the
operation. Member initial values still take precedence. An empty opt-in leaves
running members unchanged. Only writable, nonsensitive own attributes already
listed in `inherit` may be reconciled; primary keys, sensitive attributes and
known identity/scope binding names are excluded. Applications must additionally
protect any custom identity fields through their own policies and declarations.

Inheritance requests retain the receiving agent's activation authority. Native
Ash authorization runs even when the proposed values are unchanged, and the
receiving resource's ordinary types reject incompatible values. Failed members
or operation deadlines fail the tracked operation rather than imply completion.

An application middleware may stage its own follow-on native configuration by
calling its existing `next` continuation against the proposed context and
combining deferred directives. If that configuration fails, return the original
context and discard all effects. The inheritance acknowledgement is a deferred
directive, so it is sent only after the complete middleware chain and native
state adoption succeed; no application callback is stored in SDK configuration.

Fresh team startup runs its initial topology under the receiving activation's
native scope after the outer start command is authorized. An independently
owned nested team therefore uses its own principal for its initial state
updates. Failure cleanup is correlated to that in-flight start and follows the
same native retention path. Normal public topology commands retain the actual
caller's scope. Restoration preserves the saved graph and does not apply a
new caller's constructor topology; use an authorized public topology command
for an explicit change.

Restoring a team through its public start command waits for the receiver-owned
saved-topology reconciliation, including restored nested teams. Fresh constructor
topology does not replace that saved graph. If saved reconciliation fails, start
returns the failure and retains the existing identity for inspection and repair;
it does not run fresh-start cleanup or delete the retained agent.

## Receiver-owned member stops

Team `stop_member`, removal, replacement and retirement deliver graceful cleanup
to the exact current member address. The receiving activation applies its normal
native lifecycle policies with its own bound scope. The coordinating operation
requires both successful cleanup preparation and the matching verified clean
process exit. An exit alone is not a successful cleanup acknowledgement. Native
cleanup rejection fails the operation and leaves the member alive for inspection
and repair; a crash before completion fails it instead of reporting a clean stop.

Each stop installs its own tagged monitor for the exact target, so it does not
rely on a logical owner remaining alive to forward an exit. Dead-owner subtree
reconciliation may observe an already absent old incarnation and rebuild it;
this is recorded as observed absence, not successful cleanup preparation.
The coordinator retains target and owner addresses inside its current operation,
including when the desired topology removes them. These transient operation
facts do not add another persistence path or scope.

Late-activation cleanup first records a pending failure fact through the ordinary
native owner update. An unauthorized private Started message cannot skip that
admission merely because it proposes no topology changes. Exact pending cleanup
addresses correlate the receiving result; repeated pending requests emit no
additional effect.

Public direct child `stop` commands retain the actual caller's authorization.
Parent-death handling continues through the child's existing receiver-bound
Ownership action. The lower-level `StopChild` directive currently uses its
existing plain signal path; it is not covered by this Team stop contract.


## Requester-authorized messages

Use the existing native `send` action for both member and coordinator messages:

```elixir
MyApp.Agents.squad_send(coordinator_pid, %{
  member: :self,
  requester: :researcher,
  type: "ai.react.deliver",
  payload: %{text: "Findings ready", request_id: request_id}
}, scope: researcher_scope)
```

`:self` targets the actual coordinator, including when a member's logical owner
is another member. A named target selects a running member. Native nil or
`:self` requesters retain coordinator-principal semantics. Sending never activates
an offline target, waits for a reply or redirects an accepted message to a later
replacement process. A processing receipt is not a delivery acknowledgement.

A child retains its original authenticated principal at the external command and
owning-resource admission boundaries. Configure the native check together with
application identity, tenant and payload permission checks:

```elixir
policy action(:send) do
  forbid_unless MyApp.CurrentAgentIdentity
  forbid_unless MyApp.ConversationPayloadPermission
  authorize_if {Aikido.Team.PolicyChecks.MemberMessaging, types: ["ai.react.deliver"]}
end
```

The `types` list is required and matches exact signal names; it has no default
permission or wildcard expansion. A type grant alone is insufficient: signals
such as `ai.react.deliver` accept model and execution configuration as well as
text. Applications must restrict the delivered payload to their grant, for
example text, request ID and permitted display metadata. The SDK check does not
claim arbitrary payload fields are safe.

Native member-principal proof uses the current coordinator state and immutable
member activation identity, with the same bounded-read and intentionally shared
principal semantics as coordination reads and delegation. The receiving agent
then executes under its own bound scope and normal native policies. The host
must not substitute a parent actor or use a direct foreign-scope AI delivery.

The verified message context distinguishes the actual coordinator transport
sender (`context.aikido_sender`) from its attested requester
(`context.aikido_requester`). The requester contains only its member name, durable
reference and recorded incarnation, derived from adopted membership after
admission. This is provenance at send time, not a separate permission grant or a
promise the requester is still alive at receive time. Payload `from` fields and
caller-supplied provenance are not authority. Exact recipient PID and resource
address prevent delivery to a different replacement incarnation.

The playground's Team page includes **Send as counter to coordinator**. Its
browser principal is deliberately shared by the public example's members; the
control acts on behalf of counter and displays the native requester name.
Private applications should use distinct principals and the policies above.
