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
| `/examples/adaptive-tools` | Prepare application-selected tools; refresh during setup and queue a message |
| `/examples/lua-permissions` | Change the Lua function surface and inspect actor/tenant propagation |
| `/examples/verified-work` | Deliver a task and todo atomically; verify evidence after bounded continuation |
| `/examples/resilience` | Exercise deadlines, retries, cancellation and tool loop guards |
| `/examples/recovery` | Stop/start the same permanent identity and verify retained conversation |
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

See [the Makewright scenario checklist](MAKEWRIGHT.md) for prescribed offline flows
and their integration tests.

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

AI pages default to a scripted offline model. To use a real provider, open any
AI example and use **AI provider · shared by all AI examples**:

1. Choose **Live · your provider**.
2. Select **z.ai · standard API** or **z.ai · coding plan** for the key you have.
3. Enter your model ID and API key, then select **Save AI settings**.
4. Start an example and send a task. All AI examples and their fixed/dynamic
   workers use this browser session's saved provider settings at startup.

The provider list comes from ReqLLM's registered providers. Provider, model and
mode are saved per signed browser identity in AshSqlite. AshCloak encrypts API
keys; ordinary reads do not decrypt them, and the form never renders saved keys.
Agent checkpoints retain only the browser credential reference. Restarting the
server or browser retains these settings; clearing the browser cookie creates a
new identity. Restart an active example after changing provider or model.
An empty key field keeps the saved key for that provider. The z.ai standard and
coding-plan entries share one account key; provider environment keys such as
`ZAI_API_KEY` can also be used when saving.

The example creates `.local/settings.sqlite3` and a random 32-byte
`.local/credential.key` automatically, and applies native Ecto migrations at
startup. Both files are gitignored. The directory is restricted to its owner
(mode 0700), and the vault key uses mode 0600. Preserve both files to retain
credentials: the key is needed to decrypt the database. This protects the database
when copied alone; it does not protect against someone who can read both files.
Set `AIKIDO_EXAMPLES_SETTINGS_DIR` to choose another local directory. Tests use
an isolated temporary database and vault key. This is example-app configuration
storage; agent persistence continues to use DurableServer.

Live mode uses native ReqLLM for every AI page, including streaming pages.
The resilience page keeps deterministic retry/wait simulations in offline mode;
its live mode uses provider-appropriate timeouts and prompts for the loop-guard
scenarios. The Lua checkbox controls whether Ash AI/AshLua tools are added to
ordinary assistants; specialized scenarios retain their dedicated tool sets.
See [AI.md](AI.md) for tool and provider details.

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
route AgentExamples.Counter.Signals.Add, AgentExamples.Counter.Actions.Increment

route [AgentExamples.Counter.Signals.Increase, AgentExamples.Counter.Signals.Decrease],
      AgentExamples.Counter.Actions.Adjust

route "**", AgentExamples.Counter.Actions.CountAll
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
[pure action](lib/agent_examples/counter/actions/increment.ex). Resource files sit
beside their own `signals/`, `actions/` and, when needed, `directives/` folders.
The module namespaces match those folders. Compare
[Notebook](lib/agent_examples/notebook.ex) with its
[embedded Journal](lib/agent_examples/journal.ex).
[Work](lib/agent_examples/worker/actions/work.ex) shows the complete asynchronous
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

The signal-team, nested-teams and research-team pages share a live ownership
tree. Nodes show names and status colors; teams have larger nodes. Select a node
to open its current state, task, model-turn count, tool inputs/results and answer.
Existing AgentServer subscriptions update the diagram and open popup without
polling. Enter opens a focused node, Escape closes the popup, and branch focus
with parent/root navigation explores deeper teams. Each diagram shows at most
80 nodes across four levels; the underlying team is not limited by that view.
“Tool calls pending” includes time spent in gates or delegated work; it does not
claim that a tool is executing CPU work.

In the team example, **Run Lua script** is the model-facing `run_lua` tool. AshLua
exposes the domain's `agents` namespace: `members`, `spawn`, `delegate`, `stop`
and `remove`. For example, `agents.delegate({input = {member = "analyst",
text = "Review this evidence"}})` runs the scoped Ash delegation action. That
action sends a task signal through the team; the teammate's answer returns as a
correlated result signal. The tool task waits, while agent mailboxes stay responsive.
Expand a tool entry to inspect its script/input and result. Tool failures remain
marked **Failed** even if the model subsequently completes the conversation.
The offline script reads the roster before spawning and reuses workers on later prompts.

The **Recursive quicksort** page (`/examples/quicksort`) demonstrates BEAM process
fan-out without an AI provider. Start the example and sort 4,096 shuffled integers:
every nonempty partition gets an Aikido agent, including singleton partitions.
Each node spawns its smaller/larger children after choosing a pivot; child readiness
and sorted results travel through typed signals. Reducers only compute partitions
and return directives. Native Ash notifications publish progress to LiveView.

The counters and depth histogram cover the entire tree. Select a node in the
six-level diagram or the bounded node list to inspect a subtree. Rendering limits
never limit agent creation. A child stops after its parent records the sorted result;
its recorded node remains available for inspection. Stopping the root releases any
remaining descendants and deletes their temporary snapshots. Start a new
example to sort another list. The form accepts up to 100,000 values, and the example
runtime permits 20,000 concurrent I/O tasks to accommodate large bursts of spawning
and progress notifications. This is a lifecycle demonstration, not a claim that
process-based quicksort outperforms `Enum.sort/1`.

Benchmark the actual recursive tree and its UI with `mix bench.quicksort`.
See [the benchmark guide](bench/README.md) for native EKV shard comparisons,
checkpoint/WAL measurements, process cleanup checks and performance limits.
The UI maintains counts incrementally and visits only visible branches. Display summaries live in the example app independently of the LiveView and
sorting processes, so reconnects retain recorded nodes and counts. This history
is in memory and does not survive an app restart. Child activation failures return
signals to the parent, which retains the partition and retries transient failures
up to eight times with exponential backoff capped at ten seconds. Readiness makes
pending retries obsolete; exhaustion marks the affected branch and its ancestors
failed. This does not guarantee recovery from sustained storage overload.

For the 100,000-agent stress test, use eight native EKV shards and a fresh directory:

```sh
AIKIDO_EXAMPLES_EKV_SHARDS=8 AIKIDO_DURABLE_DIR=_build/quicksort-eight-shards mix phx.server
```

Do not reuse a one-shard directory with eight shards: EKV fixes the physical
partitioning when the store is created. The normal one-shard configuration stays
compatible with existing example stores. Both configurations checkpoint agents;
this setting does not disable persistence. Browser progress renders at most ten
times per second, with terminal root events flushed immediately. Every node's
status is retained independently of that rendering rate.

The live research demo defaults to 40 model turns, three minutes per model call,
and one hour per tool call and top-level request. Transient model failures
get up to four retries with bounded backoff, still inside the shared run deadline.
Nested assignments inherit
the parent's remaining absolute deadline instead of receiving fresh budgets.
`agents.delegate` accepts `worker_lifecycle = "stop"` for one-off workers; omitted
or `"keep"` retains reusable teammates. Select a tree node for its activity/state.
Single-agent examples instead offer **View current agent state** in Under the hood,
using the existing subscribed, credential-free display projection.

Agents use periodic DurableServer checkpoints by default (30 seconds). Their start
action accepts `sync` policy overrides, inherited by children. Overlapping team
spawns queue behind the active topology operation rather than failing with an
operation-in-progress error. This keeps parallel Lua tool calls usable.

Team tool failures use native Ash AI and AshLua error protocols to explain how
to recover from invalid member names, duplicate spawns, limits and deadlines.
Lua error tables are normalized before JSON serialization, including scripts
that return `nil, err` instead of raising with `assert`. Unexpected internal
failures provide recovery guidance without returning raw exception data.

Team diagrams retain stopped members as grey nodes for the current run. Select
one to inspect its last recorded task, result and state. This is UI history;
retired processes and their subscriptions are still released. Starting a new run
creates a new tree.

The Delegated work sidebar aggregates tasks from the entire recorded team tree,
including retained stopped subteams. Each task identifies its dispatching team
and the full member path, so same-named researchers remain distinguishable.
