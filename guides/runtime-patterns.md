# Choosing a Runtime Pattern

Use Ash agent resources (`Aikido.Ash.Agent`) for typed agent state and domain actions.
Add `Aikido.Ash.Team` when an agent manages a named topology of workers or nested
teams. Add `Aikido.Ash.AI` for model turns and dynamically supplied tools.

The default `Aikido` supervision tree uses DurableServer for activation, snapshots,
and recovery. Configure its backend with `durable: [...]`. Use `Aikido.Durable`
for a separately configured keyed pool; it delegates process ownership and storage
to DurableServer. InstanceManager and the pod API have been removed.

`Aikido.Agent` remains the pure action/signal engine. `Aikido.AgentServer` is the
runtime callback implementation hosted by DurableServer. Configure
`persistence :temporary` to delete snapshots on stop. Actions own state transitions;
directives perform I/O and return results through signals.

`SpawnAgent` starts durable child agents and snapshots their current logical parent. Teams add desired topology,
dependencies, ownership, lazy activation, dynamic worker templates, and task
receipts. A team resource can itself be a member or a worker template.

A `partition` scopes logical identities inside a runtime instance; it does not
provide Ash authorization or security isolation. Use Ash actors, tenants, and
policies for application access control.

See [teams](teams.md), [multi-tenancy](multi-tenancy.md),
and the runnable `examples/agent_app` application.

## Lua lifecycle hooks

AI agents and teams accept `hooks` at startup. `Aikido.AI.ask/3` also accepts a
per-request `hooks:` override; `[]` disables configured hooks for that run.
The `ai` and `react` DSL sections can declare defaults using the same hook maps.

```elixir
hooks = [
  %{
    name: "briefing",
    event: :before_model,
    mode: :sync,
    script: ~s(return {context = "Check the evidence before answering."})
  },
  %{
    name: "observer",
    event: :after_tool,
    mode: :async,
    script: ~s|aikido.send_context("Observed tool: " .. event.name)|
  }
]

MyApp.Agents.assistant_start!(%{model: "zai:glm-4.7", tools: tools, hooks: hooks})
```

Events are `run_started`, `before_model`, `after_model`, `before_tool`,
`after_tool`, `run_completed`, `run_failed`, and `run_cancelled`. Each Lua
`event` table includes `type`, `request_id`, and `iteration`. Run-start events
include `query`; before-tool events include `tool_call` (id, name, arguments);
after-tool events include `tool_call_id`, `name`, and `content`. After-model
events include the normalized `turn`; completion includes `result`.

Hooks are considered in declaration order at an event; asynchronous completion
order is independent. A synchronous hook runs
to completion before the affected step proceeds, but runs in a supervised task
so the agent can still receive cancellation and other signals. It returns nil
or a table with `decision = "continue"`, optionally with a `context` string.
`decision = "deny"` with an optional `message` fails the run before releasing
the held effect. Lua errors and invalid results also fail closed. This does not
undo effects that have already been dispatched. Terminal synchronous hooks
finish before the final completed/failed status is published.

Async hooks do not delay the loop, and their return values are ignored. They
can call `aikido.send_context(text)` or `aikido.send_signal(type, data)`.
Both target the originating agent. Custom signals carry the originating
request ID; application actions should reject stale IDs where relevant.
Internal `ai.react.*` signals cannot be sent through the custom-signal helper.
An async Lua failure is recorded in `ai.hook_errors` (the latest 20 errors)
without failing the run. Hook failures do not recursively invoke failure hooks.

Hook context is queued by an action, then added as a labeled user-role context
message immediately before the next model request. It never changes a request
already in flight or separates a tool call from its results. Context for an old
or finished run is ignored. There is no guarantee an async observer finishes
before the run's last model request; use a synchronous hook when that context
must be present. Gates use request IDs and sequence tokens to ignore stale or
duplicate completions, and cancellation invalidates their continuations.

Each invocation gets a fresh sandboxed VM. Sync hooks only receive `event` and
the safe Lua standard library; only async hooks receive the signal helpers.
They cannot access the model's tool registry or write agent state. Ash types
validate hook configuration and decisions; Ash Lua owns value encoding.
Defaults are 100,000 VM instructions, a call depth of 64, and 1 MiB per string.
Override these with `max_instructions`, `max_call_depth`, and `max_string_bytes`
on a hook. Hook tasks are ordinary supervised tasks, not durable jobs; saved
run state does not itself resume an interrupted VM or replay an external effect.

Run the example app and open `/examples/hooks` for an offline demonstration,
including the hook context panel, signal timeline, and expandable source code.
