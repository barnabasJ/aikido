# Ash agent example app

A standalone OTP app using the Aikido checkout two directories above it. Its
`AgentExamples.Agents` Ash domain is the public interface to agent and team resources.
No database, network services, or model API keys are required.

Start the browser playground from this directory:

```sh
mix deps.get
mix phx.server
```

Open [localhost:4000](http://localhost:4000). Every example has its own LiveView
page with a description, a state/workflow visual, interactive controls, and a
live signal inspector. Each page also includes the exact source definitions,
with independent code accordions: agents and slices open initially, actions,
directives, and supporting modules closed. The headers show module names and
source paths; live updates preserve your open/closed choices.
The index links to all ten pages. No Node installation,
asset build, database, or API key is needed for offline mode.

| Page | Browser interaction |
| --- | --- |
| `/examples/counter` | Change the count and watch its gauge |
| `/examples/checklist` | Add and complete items; inspect progress |
| `/examples/notebook` | Append notes to the embedded journal |
| `/examples/worker` | Submit background work and receive its result |
| `/examples/team` | Inspect fixed members and send signals to the counter |
| `/examples/nested-teams` | Inspect the fixed home squad, spawn/remove subteams, and signal their counters |
| `/examples/assistant` | Chat with a tool-equipped assistant |
| `/examples/researcher` | Try the research role independently |
| `/examples/reviewer` | Try the review role independently |
| `/examples/research-team` | Run orchestration and watch dynamic workers appear |

The nested-teams page builds one mixed ownership tree. Choose an agent or team
in **Parent node**, choose **Agent** or **Team**, and spawn a child. Repeat at
any depth: for example, `lead → helper → branch → inner` mixes a fixed agent,
a dynamic agent, and two dynamic teams. The fixed `home` team can independently
spawn dynamic workers in the same tree. The nearest team's `add_member` action
manages creation, with the selected agent recorded as `owner`. Agents need no
spawning slice or additional signal declaration. Stopping the root stops every descendant.

Runs belong to a signed browser session and survive navigation and reloads.
They are held in memory until you stop them or stop the server. The Stop button
releases the example's processes, including team descendants. The server binds
to the local machine; use `PORT=4001 mix phx.server` to choose another port.

AI pages default to a scripted offline model. To try live mode, set
`ZAI_API_KEY` in the server's environment, restart the server, choose Live, and
enter an enabled model ID. Keys are never entered into the web form. The Lua
checkbox controls whether actual Ash AI/AshLua tools are added to the runtime
tool list. See [AI.md](AI.md) for tool and provider details.

The command-line demos are also available:

```sh
mix deps.get
mix format
mix demo
mix test
iex -S mix
```

Elixir 1.19 and OTP 28 or later are required. The app includes `Aikido` in its supervision tree, starting the default
`Aikido.Default` runtime. Agent resources use it automatically. The demo prints results and stops
its own agents, so it can be run repeatedly. It reserves IDs beginning `demo-`.

The [AI examples](AI.md) add a top-level AI orchestrator, fixed workers,
dynamic workers created by the orchestrator and its workers, runtime tool
objects, Ash AI action tools, and an AshLua tool surface. Run `mix ai.demo`
offline or `mix ai.live` with a z.ai key.

## Examples

| Resource | What it demonstrates | Domain calls |
| --- | --- | --- |
| `AgentExamples.Counter` | Typed arguments and a pure state transition | `counter_start`, `counter_add`, `counter_list`, `counter_stop` |
| `AgentExamples.Checklist` | Multiple commands and business errors without state changes | `checklist_add`, `checklist_complete` |
| `AgentExamples.Notebook` | Own state plus an embedded Ash journal slice | `notebook_append` |
| `AgentExamples.Worker` | An action returns AsyncTask; a result signal routes to another action | `worker_run` |
| `AgentExamples.Team` | Child agents, asynchronous signals, and lifecycle cleanup | `team_start`, `team_send`, `team_stop` |

Every generated interface also has a bang version. The resource's update
arguments are Ash types, so invalid inputs fail before producing a signal.
Agent state uses `schema do` blocks with native Ash `attribute` declarations.
The transformer installs them as resource attributes; no separate state module is needed.

The formatter imports Aikido's generated `locals_without_parens` rules and Ash's
DSL rules. From the repository root, `mix spark.formatter` regenerates Aikido's
list, and `mix spark.formatter --check` checks it against the DSL extensions.
Root `mix format` also covers this example application.

## Try the domain

```elixir
alias AgentExamples.Agents

counter = Agents.counter_start!(%{id: "my-counter"})
counter = Agents.counter_add!(counter, %{amount: "4"})
counter = Agents.counter_inspect!(counter)
counter.count # => 4

notebook = Agents.notebook_start!(%{id: "my-notebook"})
notebook = Agents.notebook_append!(notebook, %{text: "Hello from an Ash slice"})
notebook = Agents.notebook_inspect!(notebook)
notebook.journal.entries # => ["Hello from an Ash slice"]

Agents.counter_stop!(counter)
Agents.notebook_stop!(notebook)
```

Start and signal actions return compact references and receipts. Inspect state
explicitly, or list live snapshots with filters:

```elixir
Agents.counter_list!(%{filter: [id: "my-counter"]})
```

Teams also accept their full initial topology in the start call:

```elixir
team = Agents.team_start!(%{
  topology: %{
    "counter" => %{resource: AgentExamples.Counter, initial_state: %{count: 10}},
    "worker" => %{resource: AgentExamples.Worker, depends_on: ["counter"]}
  }
})
Agents.team_stop!(team.id)
```

## Read the code

Start with [the domain](lib/agent_examples/agents.ex), then
[Counter](lib/agent_examples/agents/counter.ex) and its
[pure action](lib/agent_examples/actions/add.ex). Compare
[Notebook](lib/agent_examples/agents/notebook.ex) with its
[embedded Journal](lib/agent_examples/slices/journal.ex).
[Work](lib/agent_examples/actions/work.ex) shows the complete asynchronous
signal chain; its uppercase task is a local stand-in for one blocking tool call.
[Demo](lib/agent_examples/demo.ex) subscribes before sending work so it can
observe completion without polling or sleeps. The tests cover these behaviors.

Actions return the next state. Directives perform I/O and return promptly.
Results return as signals; a receiving action decides the next transition.
The demo and tests make synchronous calls as external clients, never inside
directive execution.

Agent state changes run in processes. Stop terminates a process; it does not
permanently delete its durable identity. Live snapshots can become stale as new
signals arrive. See the repository's
[Ash integration guide](../../guides/ash-integration.md) and
[runtime patterns](../../guides/runtime-patterns.md).

The default runtime uses DurableServer with a local EKV store under
`_build/aikido_durable`. Configure `{Aikido, durable: [data_dir: "priv/agent-state"]}`
for a stable directory, or supply a shared DurableServer backend. Agent and
slice serialization callbacks remain supported.
