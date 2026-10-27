defmodule Aikido.AiReact.ConversationHandoff do
  @moduledoc "Model-written context handoff at clean ReAct turn boundaries."
  alias Aikido.AiReact.Directives.LLMCall
  alias ReqLLM.Context

  @doc "Instructions used unless the application supplies handoff_prompt."
  def instructions do
    """
    This conversation is about to be replaced; your output is the ONLY thing your successor receives.

    Write a complete HANDOFF for the agent taking over this run. It must cover:

    - The mission and exact identifiers, including the work item, branch and workspace when applicable.
    - The standing procedure and WHERE IN IT YOU ARE (the current phase).
    - Decisions made so far and why, constraints and user preferences.
    - Work completed: evidence, files changed, commits, test results and review verdicts when applicable.
    - Work remaining, unresolved problems and relevant tool results.
    - The exact NEXT ACTION your successor must take first.

    Facts only, no pleasantries. This document is consumed by an agent, not a human.
    """
  end

  @doc "Whether a ready normal model request has reached the configured handoff budget."
  def required?(state, %LLMCall{mode: :normal}) do
    options = Map.get(state, :options) || %Aikido.AiReact.Options{}

    state.status == :running && is_nil(state.handoff_pending) &&
      state.pending_tool_calls == [] && options.handoff &&
      is_integer(options.context_max_tokens) &&
      Aikido.AiReact.Conversation.input_token_count(state) >=
        max(options.context_max_tokens - options.handoff_buffer_tokens, 0)
  end

  def required?(_state, _directive), do: false

  @doc "Mark a handoff pending and replace a model request with the handoff instructions."
  def prepare_request(state, %LLMCall{} = directive) do
    options = Map.get(state, :options) || %Aikido.AiReact.Options{}
    count = state.handoff_count + 1

    context =
      directive.context
      |> Context.append(Context.user(options.handoff_prompt || instructions()))

    directive = %{directive | mode: :handoff, handoff_id: count, context: context, tools: []}
    {%{state | handoff_count: count, handoff_pending: count, handoff_regenerations: 0}, directive}
  end

  @doc "Regenerate an unusable summary within its explicit bound, retaining the original conversation."
  def regenerate_document(state, reason) do
    attempts = Map.get(state, :handoff_regenerations, 0)

    if reason in [:empty_or_invalid_document, :document_exceeds_context_limit] &&
         attempts < state.options.handoff_max_regenerations do
      count = state.handoff_count + 1

      correction =
        case reason do
          :empty_or_invalid_document ->
            "The previous summary was empty or not a final text document. Return a nonempty plain-text handoff, without tool calls."

          :document_exceeds_context_limit ->
            "The previous summary exceeded the replacement context budget. Write a substantially shorter handoff while preserving the mission, identifiers, evidence and next action."
        end

      context =
        state.context
        |> Context.append(Context.user(state.options.handoff_prompt || instructions()))
        |> Context.append(Context.user(correction))

      directive = %LLMCall{
        mode: :handoff,
        handoff_id: count,
        context: context,
        tools: [],
        client: state.client,
        model: state.model,
        llm_opts: state.llm_opts,
        options: state.options,
        request_id: state.request_id,
        deadline_at: state.deadline_at,
        iteration: state.iteration + 1
      }

      Aikido.Types.ActionResult.new(
        state: %{
          state
          | handoff_count: count,
            handoff_pending: count,
            handoff_regenerations: attempts + 1
        },
        directives: [directive]
      )
    else
      :exhausted
    end
  end

  @doc false
  def active?(state, data),
    do:
      state.status == :running && state.request_id == data.request_id &&
        not is_nil(Map.get(state, :handoff_pending)) && state.handoff_pending == data.handoff_id
end
