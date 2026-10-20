defmodule Aikido.AI.Handoff do
  @moduledoc "Model-written context handoff at clean ReAct turn boundaries."
  alias Aikido.Slices.AiReact.Directives.LLMCall
  alias ReqLLM.Context
  alias Aikido.AI.Context, as: Conversation

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
    options = Aikido.AI.Options.resolve(Map.get(state, :options))

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
  def complete(state, data) do
    if active?(state, data) do
      response = data.turn
      turn = ReqLLM.Response.classify(response)

      cond do
        turn.type != :final_answer || !is_binary(turn.text) || String.trim(turn.text) == "" ->
          fail(state, Map.put(data, :reason, :empty_or_invalid_document))

        turn.finish_reason == :length ->
          fail(state, Map.put(data, :reason, :truncated_document))

        true ->
          document = String.trim(turn.text)
          system = Enum.filter(state.context.messages, &(&1.role == :system))
          context = Context.new(system)

          context =
            Context.append(
              context,
              Context.user(
                "You are taking over mid-run. Your predecessor left this handoff:\n\n" <>
                  document <> "\n\nContinue from the next action."
              )
            )

          context =
            Enum.reduce(state.queued_messages, context, fn text, context ->
              Context.append(context, Context.user(text))
            end)

          replacement = Conversation.replace_context(state, context)
          tokens = replacement.estimated_tokens
          options = Aikido.AI.Options.resolve(state.options)

          if tokens >= options.context_max_tokens do
            fail(state, Map.put(data, :reason, :document_exceeds_context_limit))
          else
            usage =
              Map.merge(state.usage, ReqLLM.Response.usage(response) || %{}, fn _, old, new ->
                if is_number(old) && is_number(new), do: old + new, else: new
              end)

            state =
              Map.merge(replacement, %{
                context: context,
                handoff_pending: nil,
                last_handoff: %{
                  document: document,
                  before_tokens: current_tokens(state),
                  after_tokens: tokens,
                  id: data.handoff_id
                },
                last_input_tokens: nil,
                queued_messages: [],
                streaming_text: "",
                streaming_thinking: "",
                usage: usage
              })

            effect = %LLMCall{
              mode: :resume,
              options: state.options,
              iteration: state.iteration + 1,
              model: state.model,
              client: state.client,
              context: context,
              request_id: state.request_id,
              llm_opts: state.llm_opts
            }

            Aikido.Hooks.transition(
              Aikido.Types.ActionResult.new(state: state, directives: [effect]),
              :after_model,
              %{handoff: true}
            )
          end
      end
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  @doc false
  def fail(state, data) do
    if active?(state, data) do
      state =
        Map.merge(state, %{
          status: :failed,
          error: {:context_handoff_failed, data.reason},
          handoff_pending: nil,
          hooks_pending: %{}
        })

      Aikido.Hooks.transition(Aikido.Types.ActionResult.new(state: state), :run_failed, %{
        reason: state.error
      })
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp active?(state, data),
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
