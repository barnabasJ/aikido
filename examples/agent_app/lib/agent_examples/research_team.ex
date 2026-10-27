defmodule AgentExamples.ResearchTeam do
  @moduledoc "A research orchestrator that creates its workers and squads dynamically."
  use Ash.Resource,
    domain: AgentExamples.Agents,
    extensions: [Aikido.Agent.Extension, Aikido.AI.Extension, Aikido.Team.Extension]

  agent do
    name "example_research_team"
  end

  # Optional role defaults; callers supply the model and tools at creation.
  ai do
    options %{completion: :tasks, model_timeout_ms: 600_000}
    llm_opts max_tokens: 16_384, receive_timeout: 600_000, temperature: 0.2

    system_prompt """
    You lead a research organization. Demonstrate dynamic, hierarchical collaboration:
    Start with an empty roster and create purpose-specific squads with the squad
    template. For a substantial task, create an
    investigation squad and an independent verification squad. Ask the investigation
    squad to create a focused subteam, whose researchers may use specialist subagents.
    Delegate concrete questions, collect the findings, then synthesize one answer.

    Include a remaining team-depth budget in every squad assignment. Start squads
    with a budget of 1: they may create one further squad level, then pass 0 to it.
    At budget 0, use researchers without creating more squads. Use at most two new
    squads per team and one specialist per researcher; avoid unnecessary duplication.
    Keep squads that you will reuse. For one-off researcher assignments, set
    worker_lifecycle = "stop" in the delegate input so the worker stops after its
    result is recorded; the default "keep" leaves it available.
    These are planning instructions; the configured member limits still apply.
    Even for a brief demo input, use one squad and one nested squad to demonstrate
    the hierarchy, giving each a small, distinct task. Explain the division of work.

    Use run_lua and the agents namespace. First inspect lua_docs with empty input
    for the API index; fetch exact names such as agents.spawn and agents.delegate.
    Create a squad with agents.spawn({input = {name = "investigation", template = "squad"}}).
    Lua actions return result, err. Use return assert(agents.members({})) to inspect
    the roster, and return assert(agents.delegate({input = {member = "investigation",
    text = "Investigate the assigned question. Remaining team-depth budget: 1."}}))
    to delegate. Use mode = "background" for independent work: delegate returns
    a task ID immediately, and the team delivers the result later as a conversation
    message. Foreground waits for the answer. An existing foreground task can be
    backgrounded with agents.delegate({input = {task_id = "the-task-id", mode = "background"}})
    without cancelling the worker. Do not duplicate an assignment while awaiting its result.
    Check errors or use assert so failed work is visible. Start useful
    independent branches before collecting their findings. Use only supplied tools
    and base your final answer on the returned evidence.
    """

    max_iterations 40
  end

  team do
    max_members 8

    inherit [
      :tools,
      :tool_options,
      :tool_context,
      :model,
      :client,
      :max_iterations,
      :options,
      :llm_opts
    ]

    worker :researcher, AgentExamples.Researcher, max_members: 6
    worker :squad, AgentExamples.ResearchSquad, max_members: 2
  end
end
