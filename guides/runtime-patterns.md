# Choosing a Runtime Pattern

Use Ash agent resources (`Aikido.Ash.Agent`) for typed agent state and domain actions.
Add `Aikido.Ash.Team` when an agent manages a named topology of workers or nested
teams. Add `Aikido.Ash.AI` for model turns and dynamically supplied tools.

The default `Aikido` supervision tree uses DurableServer for activation, snapshots,
and recovery. Configure its backend with `durable: [...]`. Use `Aikido.Durable`
for a separately configured keyed pool; it delegates process ownership and storage
to DurableServer. InstanceManager and the pod API have been removed.

`Aikido.Agent` remains the pure action/signal engine. `Aikido.AgentServer` is the
runtime callback implementation shared by the durable host and deliberately
nonpersistent instances (`durable: false`). Actions own state transitions;
directives perform I/O and return results through signals.

`SpawnAgent` supports direct child processes. Teams add desired topology,
dependencies, ownership, lazy activation, dynamic worker templates, and task
receipts. A team resource can itself be a member or a worker template.

A `partition` scopes logical identities inside a runtime instance; it does not
provide Ash authorization or security isolation. Use Ash actors, tenants, and
policies for application access control.

See [teams](teams.md), [multi-tenancy](multi-tenancy.md),
and the runnable `examples/agent_app` application.
