defmodule Aikido.AiReact.Handoff do
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

  @doc false
  def plan({:ok, result}) do
    state = result.state
    options = Map.get(state, :options) || %Aikido.AiReact.Options{}

    if state.status == :running && is_nil(Map.get(state, :handoff_pending)) &&
         Map.get(state, :pending_tool_calls, []) == [] && options.handoff &&
         is_integer(options.context_max_tokens) do
      Enum.reduce(result.directives, {:ok, %{result | directives: []}}, fn
        %LLMCall{mode: :normal} = effect, {:ok, result} ->
          if current_tokens(state) >=
               max(options.context_max_tokens - options.handoff_buffer_tokens, 0) do
            count = Map.get(state, :handoff_count, 0) + 1

            context =
              Context.append(
                effect.context,
                Context.user(options.handoff_prompt || instructions())
              )

            effect = %{effect | mode: :handoff, handoff_id: count, context: context, tools: []}
            state = Map.merge(result.state, %{handoff_count: count, handoff_pending: count})
            {:ok, %{result | state: state, directives: result.directives ++ [effect]}}
          else
            {:ok, %{result | directives: result.directives ++ [effect]}}
          end

        effect, {:ok, result} ->
          {:ok, %{result | directives: result.directives ++ [effect]}}
      end)
    else
      {:ok, result}
    end
  end

  def plan(error), do: error

  @doc false
  def active?(state, data),
    do:
      state.status == :running && state.request_id == data.request_id &&
        not is_nil(Map.get(state, :handoff_pending)) && state.handoff_pending == data.handoff_id

  @doc false
  def current_tokens(state),
    do: max(Map.get(state, :last_input_tokens) || 0, Map.get(state, :estimated_tokens, 0))

  @doc false
  def input_tokens(usage) when is_map(usage) do
    case usage[:input_tokens] || usage["input_tokens"] do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  def input_tokens(_), do: nil
end
