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
    {%{state | handoff_count: count, handoff_pending: count}, directive}
  end

  @doc false
  def active?(state, data),
    do:
      state.status == :running && state.request_id == data.request_id &&
        not is_nil(Map.get(state, :handoff_pending)) && state.handoff_pending == data.handoff_id
end
