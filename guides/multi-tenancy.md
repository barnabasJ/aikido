# Multi-tenancy and runtime partitions

A runtime partition scopes an agent's logical identity. The same key can run in
several partitions without collision:

```elixir
{:ok, alpha} = Aikido.start_agent(MyApp.Aikido, MyApp.Worker, id: "worker", partition: :alpha)
{:ok, beta} = Aikido.start_agent(MyApp.Aikido, MyApp.Worker, id: "worker", partition: :beta)

Aikido.whereis(MyApp.Aikido, "worker", partition: :alpha)
Aikido.stop_agent(MyApp.Aikido, "worker", partition: :beta)
```

DurableServer keys include the partition. Snapshots and activation therefore
remain independent for those identities. Separately configured `Aikido.Durable`
pools also accept `partition:` on `ensure_started`, `lookup`, and `stop`.

Teams use Ash resources, and their members inherit the runtime partition from
the parent. Keep an ownership tree in one partition. The nested-team examples
show static and dynamic descendants under one root.

Partitions are namespaces, not an authorization boundary. Continue passing Ash
actors, tenant, and context to actions and tools, and enforce application policy
on exposed management actions. Separate processes can still communicate when an
application explicitly gives them that capability.

See [teams](teams.md) and [runtime patterns](runtime-patterns.md) for supervision and persistence.
