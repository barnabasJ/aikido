defmodule AgentExamples.Catalog do
  @moduledoc "The runnable examples and the descriptions shown on their LiveView pages."
  @examples [
    %{
      slug: "cron",
      title: "Recurring cron",
      eyebrow: "Scheduled signals",
      resource: AgentExamples.CronClock,
      kind: :cron,
      description: "Start and pause a recurring clock that sends a signal every two seconds.",
      detail:
        "Enable returns a Register directive under one stable job ID. Cron.Slice actions record the scheduler result, own cancellation and retry failed jobs. Each scheduled tick enters the normal signal/action pipeline. Pause rejects queued ticks and cancels the job; stopping the agent also closes its scheduler.",
      flow: ["Enable action", "Register cron", "Tick signal", "Count action"]
    },
    %{
      slug: "checkpoint",
      title: "Crash and restore",
      eyebrow: "Durable checkpoints",
      resource: AgentExamples.CheckpointCounter,
      kind: :checkpoint,
      description:
        "Compare live state with saved state by deliberately killing and restoring a counter.",
      detail:
        "Checkpoint now gracefully stops and reactivates the same permanent identity. Add an unsaved change, then send a crash signal: its directive kills the process without a final save. Start again to restore the checkpoint. This demo disables automatic crash restart and uses a one-hour periodic sync interval to make the difference visible. Ordinary Stop example saves the current value.",
      flow: ["Change state", "Checkpoint", "Hard crash", "Same ID → restore"]
    },
    %{
      slug: "quicksort",
      title: "Recursive quicksort",
      eyebrow: "BEAM · thousands of real agents",
      resource: AgentExamples.Quicksort,
      kind: :quicksort,
      description: "Watch a sorting tree spawn a real Aikido agent for every nonempty partition.",
      detail:
        "Each agent picks a pivot, spawns children for smaller and larger values, then combines their results through signals. There is no local-sort cutoff or worker pool. Each child stops after its parent receives the sorted result. The UI retains its recorded tree for inspection; stopping the root closes the remaining process. Large inputs create thousands of processes; the UI limits the visible rows rather than limiting the agents.",
      flow: ["Partition", "Spawn child agents", "Sorted result signals", "Combine"]
    },
    %{
      slug: "lua-permissions",
      title: "Lua permissions and scope",
      eyebrow: "Makewright · filtered VM functions",
      resource: AgentExamples.LuaAssistant,
      tool_policy: :required_lua,
      tools: [:scoped_lua, :scoped_lua_docs],
      kind: :ai,
      description:
        "Select Lua functions per agent and carry actor and tenant through to inner Ash actions.",
      detail:
        "Execution and documentation resolve their entrypoints from the same declarative application context. Allow or remove the scope function, then run a script or request docs. These controls simulate an app-owned permission decision; a real application must derive that decision from its own authorization rather than trusting client-supplied flags.",
      flow: [
        "Application permissions",
        "Same eval/docs entrypoints",
        "Lua → native Ash action",
        "Original actor + tenant"
      ]
    },
    %{
      slug: "adaptive-tools",
      title: "Tool setup and refresh",
      eyebrow: "Makewright · application tool configuration",
      resource: AgentExamples.AdaptiveAssistant,
      tool_policy: :fixed,
      tools: [],
      kind: :ai,
      description: "Prepare native tools from application context and refresh them during a run.",
      detail:
        "Setup simulates a remote catalog request. Switch between analysis and stamping during setup or before the next prompt. A refresh during model or tool work is applied before the next model request. Queued messages and cancellation remain available. The application owns discovery and the permitted tool set; the library builds the native Ash AI registry.",
      flow: [
        "Application context",
        "Scoped preparation action",
        "Generation-safe refresh",
        "Prepared tools → model"
      ]
    },
    %{
      slug: "verified-work",
      title: "Verified task delivery",
      eyebrow: "Makewright · bounded todo continuation",
      resource: AgentExamples.VerifiedAssistant,
      tool_policy: :fixed,
      tools: [:record_evidence],
      kind: :ai,
      description:
        "Deliver a task and its todo atomically, then require tool evidence before completion.",
      detail:
        "Deliver work to start a run. The offline model first proposes an answer without evidence. A boolean application verifier checks the explicit todo evidence. Bounded todo continuation requests more work, and the ordinary evidence tool completes the todo through a public command. No transcript access is needed.",
      flow: [
        "Message + todo",
        "Provisional answer",
        "Missing evidence → continue",
        "Evidence tool → verified answer"
      ]
    },
    %{
      slug: "verified-team",
      title: "Background work and evidence",
      eyebrow: "Makewright · native Team and Todo",
      resource: AgentExamples.VerifiedTeam,
      tool_policy: :fixed,
      tools: [:request_team_evidence, :complete_team_evidence],
      kind: :ai_team,
      description: "Track required background work with a blocking Todo and check its result through a normal tool.",
      detail: "The request tool creates a blocking Todo and assigns its evidence check through Team. An interim answer waits on that requirement. The correlated result resumes the conversation; a scoped completion tool checks the authoritative task record before recording Todo evidence. Missing evidence is an ordinary tool error. Live mode uses your shared provider for both agents.",
      flow: ["Required Todo + assignment", "Waiting on required work", "Scoped result delivery", "Evidence check → Todo complete"]
    },
    %{
      slug: "resilience",
      title: "Retries and loop guards",
      eyebrow: "Makewright · failure isolation",
      resource: AgentExamples.ResilientAssistant,
      tool_policy: :fixed,
      tools: [:text_stats, :stamp, :fail_example],
      kind: :ai,
      description:
        "Exercise retry exhaustion, deadlines, cancellation and optional tool loop limits.",
      detail:
        "Choose retry to exhaust one retry, wait to test the three-second deadline or cancel while work is pending, cycle to repeat alternating tools, or errors to repeat failing tools. All tools run through Ash AI. Cycle and error limits are opt-in; the configured limit stops the run with a visible error rather than consuming the remaining model turns.",
      flow: [
        "Deterministic failure",
        "Bounded attempts",
        "Result signals",
        "Recovery or explicit failure"
      ]
    },
    %{
      slug: "recovery",
      title: "Checkpoint recovery",
      eyebrow: "Makewright · DurableServer",
      resource: AgentExamples.RecoverableAssistant,
      tool_policy: :fixed,
      tools: [:text_stats, :stamp],
      kind: :ai,
      description:
        "Stop a permanent conversation and restore the same identity with retained history.",
      detail:
        "Send a prompt, stop the example, then start it again. This page reuses the stable agent ID and DurableServer restores the conversation. A new prompt reports how many user messages were retained. Prepared tool functions are rebuilt for each run. Interrupted effects and Lua VMs are not replayed. Delete the saved identity explicitly when you no longer need it.",
      flow: [
        "Conversation",
        "Checkpoint + stop",
        "Same ID → restore",
        "Fresh tools + retained history"
      ]
    },
    %{
      slug: "counter",
      title: "Counter",
      eyebrow: "State & contracts",
      resource: AgentExamples.Counter,
      kind: :counter,
      description:
        "Adjust a counter with typed signals and count every signal with a wildcard route.",
      detail:
        "Add uses a typed public command. Increase and decrease share one handler through a native Ash union. A wildcard handler observes all three and also counts a notice with no specific handler. Each action returns the next state, which the following action receives.",
      flow: ["Typed signal", "Shared union handler", "Wildcard observer", "Count + signals seen"]
    },
    %{
      slug: "checklist",
      title: "Checklist",
      eyebrow: "Business rules",
      resource: AgentExamples.Checklist,
      kind: :checklist,
      description: "Add work, complete it, and see state preserved when a command fails.",
      detail:
        "Add an item, then complete it. Completing an unknown item returns a business error and leaves the last good state intact.",
      flow: ["Add item", "Pending list", "Complete", "Progress"]
    },
    %{
      slug: "notebook",
      title: "Notebook",
      eyebrow: "Embedded slices",
      resource: AgentExamples.Notebook,
      kind: :notebook,
      description: "Append notes to an embedded Ash resource mounted as a slice.",
      detail:
        "The notebook title belongs to the agent. Journal entries belong to its embedded slice, which handles routed Ash actions independently.",
      flow: ["Notebook", "journal.append", "Embedded slice", "Journal entry"]
    },
    %{
      slug: "worker",
      title: "Async worker",
      eyebrow: "Signals & effects",
      resource: AgentExamples.Worker,
      kind: :worker,
      description: "Dispatch a background task and observe its result returning as a signal.",
      detail:
        "An action emits an AsyncTask directive. A supervised task uppercases your text, then a result signal re-enters the action pipeline.",
      flow: ["Action", "AsyncTask", "Result signal", "Completed state"]
    },
    %{
      slug: "team",
      title: "Signal team",
      eyebrow: "Fixed topology",
      resource: AgentExamples.Team,
      kind: :team,
      description: "Start a counter, notebook, and worker together and send them messages.",
      detail:
        "One team owns the child processes. Send typed signals to its members; stopping the team stops the entire group.",
      flow: ["Team", "Member signal", "Child action", "Child state"]
    },
    %{
      slug: "nested-teams",
      title: "Nested teams",
      eyebrow: "Static & dynamic subteams",
      resource: AgentExamples.NestedTeam,
      kind: :nested_team,
      description: "Build one mixed tree of static and dynamic agents and teams at any depth.",
      detail:
        "A fixed lead agent and home team start with the root. Select any agent or team as a parent and spawn an agent or team beneath it; repeat to extend the same tree. The nearest team manages membership, with the selected agent recorded as the child's owner. Ownership controls recursive shutdown.",
      flow: ["Parent team", "Fixed + dynamic squads", "Squad members", "Recursive shutdown"]
    },
    %{
      slug: "assistant",
      title: "AI assistant",
      eyebrow: "Runtime tools",
      resource: AgentExamples.Assistant,
      tool_policy: :optional_lua,
      tools: [:text_stats, :stamp],
      kind: :ai,
      description: "Give an assistant tools at runtime and follow its reasoning-and-tool loop.",
      detail:
        "Choose an offline scripted model or a live z.ai model. Native Ash AI tools and scoped Lua actions run through the same ReAct loop.",
      flow: ["Prompt", "Model turn", "Runtime tools", "Answer"]
    },
    %{
      slug: "hooks",
      title: "Lua lifecycle hooks",
      eyebrow: "Sync gates & async observers",
      resource: AgentExamples.HookedAssistant,
      tool_policy: :optional_lua,
      tools: [:text_stats, :stamp],
      kind: :ai,
      description:
        "Run Lua hooks before model and tool calls, and inject context asynchronously.",
      detail:
        "The briefing hook finishes before the first model call. Tool gates run in declaration order, while the async observer sends context through a signal without delaying the loop. Include deny-tools in your task to see a gate reject execution. Context received during a model call is available for the next call. The event timeline shows hook results; the agent definition below contains every Lua script. Callers can replace hooks at startup.",
      flow: ["Sync briefing", "Model & tool gates", "Async context signal", "Next model call"]
    },
    %{
      slug: "conversation",
      title: "Conversation and work tracking",
      eyebrow: "Streaming · persistent conversation",
      resource: AgentExamples.ConversationAssistant,
      tool_policy: :optional_lua,
      tools: [:text_stats, :stamp],
      kind: :ai,
      description:
        "Stream an answer, retain conversation history, and optionally wait for todos.",
      detail:
        "Start offline, add a todo, and send a prompt. The answer streams but completion waits for the todo. Complete or block the item to resolve the run. Send another prompt to see retained history, or queue a message while the model is working. Near the context limit, the model writes a handoff document and continues with fresh context. Application metadata remains plain data.",
      flow: [
        "History + queued messages",
        "Batched text / thinking",
        "Optional todo gate",
        "Completion or explicit failure"
      ]
    },
    %{
      slug: "hook-requests",
      title: "Lua request / response",
      eyebrow: "Experimental · human in the loop",
      resource: AgentExamples.InteractiveAssistant,
      tool_policy: :optional_lua,
      tools: [:text_stats, :stamp],
      kind: :ai,
      description:
        "Let a Lua hook call an application callback, wait for your answer, and continue the same script.",
      detail:
        "Every new task asks for approval before its first model request or tool call. Approval applies only to that task and is never reused from conversation history. The Lua script interprets your response and decides whether to continue or stop. The agent stays responsive while the hook task waits. Requests expire after two minutes; stopping the example closes the wait. This experiment does not resume Lua tasks after a process restart.",
      flow: [
        "Lua request",
        "Application callback → LiveView",
        "Callback returns your answer",
        "Same Lua script continues"
      ]
    },
    %{
      slug: "researcher",
      title: "AI researcher",
      eyebrow: "Worker interface",
      resource: AgentExamples.Researcher,
      tool_policy: :optional_lua,
      tools: [:text_stats, :stamp],
      kind: :ai,
      description: "Try a research worker directly through the same interface as a team.",
      detail:
        "This is the resource used for fixed and dynamic researchers. Here it runs independently, with its own role prompt and the tools supplied when started.",
      flow: ["Research task", "Evidence tools", "Model turn", "Findings"]
    },
    %{
      slug: "reviewer",
      title: "AI reviewer",
      eyebrow: "Review role",
      resource: AgentExamples.Reviewer,
      tool_policy: :optional_lua,
      tools: [:text_stats, :stamp],
      kind: :ai,
      description: "Try the fixed reviewer role as an independently addressable agent.",
      detail:
        "The reviewer checks supplied findings. It shares the assistant/team ask interface while retaining a role-specific system prompt.",
      flow: ["Findings", "Check evidence", "Review", "Assessment"]
    },
    %{
      slug: "research-team",
      title: "AI research team",
      eyebrow: "Dynamic orchestration",
      resource: AgentExamples.ResearchTeam,
      tool_policy: :required_lua,
      tools: [:text_stats, :stamp, :run_lua, :lua_docs],
      kind: :ai_team,
      description:
        "An AI orchestrator creates research squads, nested subteams and specialist agents.",
      detail:
        "The live orchestrator chooses purpose-specific investigation and verification squads. The root starts alone; it creates squads and researchers as work requires. Squads can create nested squads and researchers. Prompts pass a depth budget with delegated tasks; each team also enforces its configured member limits. Offline mode uses a deterministic worker demonstration.",
      flow: ["Orchestrator", "Create squads", "Delegate research", "Combined answer"]
    }
  ]
  def all, do: @examples
  def find(slug), do: Enum.find(@examples, &(&1.slug == slug))
  def ai?(example), do: example.kind in [:ai, :ai_team]

  @doc "The example's native tool policy; non-AI examples have no scripting choice."
  @spec tool_policy(map()) :: AgentExamples.AI.Types.ToolPolicy.t()
  def tool_policy(example), do: example[:tool_policy] || :fixed

  @doc "Whether this example supports choosing direct tools or adding Lua scripting."
  def lua_optional?(example), do: tool_policy(example) == :optional_lua

  @doc "Whether this example requires its configured Lua tools in both offline and live modes."
  def requires_lua?(example), do: tool_policy(example) == :required_lua

  @doc "Resolve the scripting choice against the example's declared tool policy."
  def lua_enabled?(example, requested?) do
    requires_lua?(example) || (lua_optional?(example) && requested?)
  end

  @doc "Build the example's tool list; fixed and required policies ignore the optional toggle."
  def tools(%{tool_policy: :optional_lua, tools: tools}, true),
    do: tools ++ AgentExamples.AI.Tools.for_lua()

  def tools(%{tools: tools}, _requested?), do: tools
end
