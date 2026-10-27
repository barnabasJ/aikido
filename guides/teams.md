# Teams

A team is an Ash agent resource with `Aikido.Team.Extension`. It can run its own actions
and AI turns while managing named agents and nested teams through the same
Ash domain interface.

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

`send`, `broadcast`, and `assign_task` route work through signals. Team and agent
resources share the domain interface. AI agents receive dynamic tools at creation;
AshAI and AshLua can expose the team's management actions as tools. The research
team example starts with only its orchestrator and dynamically creates workers,
worker-owned helpers, and nested teams.

The default Aikido runtime uses DurableServer. Team snapshots retain desired
topology; recovery rebuilds process membership and monitors, and reconciles eager
members. Agent and slice serialization callbacks remain supported. Local EKV
storage survives restarts when its disk remains available; configure a shared
DurableServer backend for machine failover. See [runtime patterns](runtime-patterns.md).

Run `examples/agent_app` and visit `/examples/nested-teams` and
`/examples/research-team` for interactive trees and expandable source definitions.

### Delegation and result delivery

`assign_task` activates a predefined lazy member before dispatching its work.
The optional `notify` argument names an orchestrator member, or `:self` for an
AI-equipped team. Terminal task results are delivered through `ai.react.deliver`:
an idle orchestrator starts a turn; an active one queues the result. Set
`metadata` to carry application-owned correlation data such as a workflow step ID.
The receiving AI run exposes structured task data in `run_metadata.task`.
Deliveries queued during an active run retain their correlation data in
`run_metadata.deliveries`.

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
