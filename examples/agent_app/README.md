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
with independent code accordions: agents and slices open initially, typed signal
definitions, actions, directives, and supporting modules closed. The headers show module names and
source paths; live updates preserve your open/closed choices.
Each URL maps to its own LiveView module under `lib/agent_examples_web/live/`.
`ExampleComponents` shares the layout, navigation and reusable visuals;
`ExamplePage` shares run startup, shutdown and subscription handling. Example
events and controls stay in their page modules.
The index links to every example page. No Node installation,
asset build, database, or API key is needed for offline mode.

| Page | Browser interaction |
| --- | --- |
| `/examples/counter` | Add, increase/decrease through one typed union handler, and count every signal |
| `/examples/checklist` | Add and complete items; inspect progress |
| `/examples/notebook` | Append notes to the embedded journal |
| `/examples/worker` | Submit background work and receive its result |
| `/examples/team` | Inspect fixed members and send signals to the counter |
| `/examples/nested-teams` | Inspect the fixed home squad, spawn/remove subteams, and signal their counters |
| `/examples/assistant` | Chat with a tool-equipped assistant |
| `/examples/hooks` | Run synchronous and asynchronous Lua lifecycle hooks |
| `/examples/hook-requests` | Answer a request from a waiting Lua hook through the example callback |
| `/examples/conversation` | Stream responses, retain history, and try todo-gated completion |
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

The hook-request page uses the portable `&AgentExamples.Playground.request/2`
callback. Each ask supplies the browser/run identity in `metadata`; the callback
reads `context.event.metadata` to route the card. Checkpoints retain the exported
function reference without capturing browser state. Pending UI cards and waiting
Lua executions remain temporary application state.

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
dynamic workers created by the orchestrator and its workers, native Ash AI tool
selection and configuration, and an AshLua tool surface. Run `mix ai.demo`
offline or `mix ai.live` with a z.ai key.

## Examples

| Resource | What it demonstrates | Domain calls |
| --- | --- | --- |
| `AgentExamples.Counter` | Typed signals, a shared union handler, and a wildcard counter | `counter_start`, `counter_add`, `counter_list`, `counter_stop` |
| `AgentExamples.Checklist` | Multiple commands and business errors without state changes | `checklist_add`, `checklist_complete` |
| `AgentExamples.Notebook` | Own state plus an embedded Ash journal slice | `notebook_append` |
| `AgentExamples.Worker` | An action returns AsyncTask; a result signal routes to another action | `worker_run` |
| `AgentExamples.Team` | Child agents, asynchronous signals, and lifecycle cleanup | `team_start`, `team_send`, `team_stop` |

Every generated interface also has a bang version. The resource's signal action
arguments are Ash types, so invalid inputs fail before producing a signal.
Agent state uses `schema do` blocks with native Ash `attribute` declarations.
The transformer installs them as resource attributes; no separate state module is needed.

Each signal defines its payload once with `use Aikido.Signal` and a `signal do`
block containing its type, source, and schema. Each attribute uses a `do/end`
block with a description of its role. Agent declarations bind that
contract directly to an Ash action implementation:

```elixir
route AgentExamples.Counter.Signals.Add, AgentExamples.Counter.Increment

route [AgentExamples.Counter.Signals.Increase, AgentExamples.Counter.Signals.Decrease],
      AgentExamples.Counter.Adjust

route "**", AgentExamples.Counter.CountAll
```

The public `add` command receives the fields declared by its signal. The list
route gives `Adjust` one native `Ash.Union` value whose tag identifies increase
or decrease. The wildcard receives arbitrary signal data and increments
`signals_seen`, including a notice with no specific handler. Generated reducers
use the owning state schema and each signal's payload types; the example agents
do not repeat those contracts in manual action declarations.

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
[Counter](lib/agent_examples/counter.ex) and its
[Add](lib/agent_examples/counter/signals/add.ex),
[Increase](lib/agent_examples/counter/signals/increase.ex), and
[Decrease](lib/agent_examples/counter/signals/decrease.ex) signals and
[pure action](lib/agent_examples/counter/increment.ex). Resource files sit
beside their own signal and implementation folders. Compare
[Notebook](lib/agent_examples/notebook.ex) with its
[embedded Journal](lib/agent_examples/journal.ex).
[Work](lib/agent_examples/worker/work.ex) shows the complete asynchronous
signal chain; its uppercase task is a local stand-in for one blocking tool call.
[Demo](lib/agent_examples/demo.ex) subscribes before sending work so it can
observe completion through subscriptions. The tests cover these behaviors.

Actions return the next state. Directives perform I/O and return promptly.
Results return as signals; a receiving action decides the next transition.
The demo and tests make synchronous calls as external clients, never inside
directive execution.

Agent state changes run in processes. With the default `persistence :permanent`,
stop retains the snapshot; `persistence :temporary` deletes it on stop. The
separate `delete` action removes saved state in either mode. Live snapshots can become stale as new
signals arrive. See the repository's
[Ash integration guide](../../guides/ash-integration.md) and
[runtime patterns](../../guides/runtime-patterns.md).

The default runtime uses DurableServer with a local EKV store under
`_build/aikido_durable`. Configure `{Aikido, durable: [data_dir: "priv/agent-state"]}`
for a stable directory, or supply a shared DurableServer backend. Agent and
slice serialization callbacks remain supported.
