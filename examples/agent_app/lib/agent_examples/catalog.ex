defmodule AgentExamples.Catalog do
  @moduledoc "The runnable examples and the descriptions shown on their LiveView pages."
  @examples [
    %{
      slug: "lua-permissions",
      title: "Lua permissions and scope",
      eyebrow: "Makewright · filtered VM functions",
      resource: AgentExamples.LuaAssistant,
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
      kind: :ai,
      description:
        "Deliver a task and its todo atomically, then require tool evidence before completion.",
      detail:
        "Deliver work to start a run. The offline model first proposes an answer without evidence. A native application verifier rejects it, the library requests another turn, and the evidence tool completes the todo through a public command. The verifier then accepts the answer. Continuation is optional and bounded; ordinary assistants still wait for external work by default.",
      flow: [
        "Message + todo",
        "Provisional answer",
        "Verifier rejects → continue",
        "Evidence tool → verified answer"
      ]
    },
    %{
      slug: "resilience",
      title: "Retries and loop guards",
      eyebrow: "Makewright · failure isolation",
      resource: AgentExamples.ResilientAssistant,
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
      kind: :ai,
      description:
        "Let a Lua hook call an application callback, wait for your answer, and continue the same script.",
      detail:
        "Send a task, then answer the request card for the stamp tool. The Lua script interprets your response and decides whether to continue or stop. Other tools can run before this gate. The agent stays responsive while the hook task waits. Requests expire after two minutes; stopping the example closes the wait. This experiment does not resume Lua tasks after a process restart.",
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
      kind: :ai_team,
      description: "An orchestrator, fixed workers, and workers that can create subworkers.",
      detail:
        "The team itself is the orchestrator. It creates a specialist; its fixed analyst creates a helper; the reviewer checks the evidence. The graph grows as tools execute.",
      flow: ["Orchestrator", "Fixed workers", "Dynamic helpers", "Combined answer"]
    }
  ]
  def all, do: @examples
  def find(slug), do: Enum.find(@examples, &(&1.slug == slug))
  def ai?(example), do: example.kind in [:ai, :ai_team]
end
