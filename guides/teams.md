# Teams

A team is an Ash agent resource with `Aikido.Ash.Team`. It can run its own actions
and AI turns while managing named agents and nested teams through the same
Ash domain interface.

```elixir
defmodule MyApp.ResearchTeam do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.Team, Aikido.Ash.AI]

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
team example demonstrates orchestrators, fixed workers, dynamically spawned
workers, workers spawning helpers, and nested teams.

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
