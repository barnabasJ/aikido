defmodule Aikido.AiReact.Actions.HandoffCompleted do
  @moduledoc "Adopts a validated handoff document, retains usage and resumes the next model turn."
  use Ash.Resource.Actions.Implementation
  alias Aikido.AiReact.{ConversationHandoff, HookQueue}
  alias Aikido.AiReact.Directives.LLMCall
  alias Aikido.AiReact.Conversation

  @impl true
  def run(input, _opts, _context) do
    input.arguments.state
    |> adopt_handoff_and_resume(Map.delete(input.arguments, :state))
  end

  @doc false
  def adopt_handoff_and_resume(state, data) do
    if ConversationHandoff.active?(state, data) do
      with {:ok, document} <- extract_handoff_document(data.turn),
           replacement <- replace_conversation(state, document),
           :ok <- check_context_capacity(replacement) do
        replacement
        |> record_handoff(state, data.handoff_id, document)
        |> accumulate_usage(data.turn)
        |> request_resumed_model_turn()
        |> HookQueue.queue_event_hooks(:after_model, %{handoff: true})
      else
        {:error, reason} ->
          Aikido.AiReact.Actions.HandoffFailed.fail_pending_handoff(
            state,
            Map.put(data, :reason, reason)
          )
      end
    else
      Aikido.Types.ActionResult.new(state: state)
    end
  end

  defp extract_handoff_document(response) do
    turn = ReqLLM.Response.classify(response)

    cond do
      turn.type != :final_answer || String.trim(turn.text) == "" ->
        {:error, :empty_or_invalid_document}

      turn.finish_reason == :length ->
        {:error, :truncated_document}

      true ->
        {:ok, String.trim(turn.text)}
    end
  end

  defp replace_conversation(state, document) do
    system = Enum.filter(state.context.messages, &(&1.role == :system))

    context =
      system
      |> ReqLLM.Context.new()
      |> ReqLLM.Context.append(
        ReqLLM.Context.user("""
        You are taking over mid-run. Your predecessor left this handoff:

        #{document}

        Continue from the next action.\
        """)
      )

    state
    |> Conversation.replace_context(context)
    |> Conversation.append_messages(Enum.map(state.queued_messages, &ReqLLM.Context.user/1))
  end

  defp check_context_capacity(state) do
    if state.estimated_tokens < state.options.context_max_tokens,
      do: :ok,
      else: {:error, :document_exceeds_context_limit}
  end

  defp record_handoff(replacement, original, handoff_id, document) do
    Map.merge(replacement, %{
      handoff_pending: nil,
      last_handoff: %{
        document: document,
        before_tokens: Aikido.AiReact.Conversation.input_token_count(original),
        after_tokens: replacement.estimated_tokens,
        id: handoff_id
      },
      last_input_tokens: nil,
      queued_messages: [],
      streaming_text: "",
      streaming_thinking: ""
    })
  end

  defp accumulate_usage(state, response) do
    usage =
      Map.merge(state.usage, ReqLLM.Response.usage(response) || %{}, fn _, old, new ->
        if is_number(old) && is_number(new), do: old + new, else: new
      end)

    %{state | usage: usage}
  end

  defp request_resumed_model_turn(state) do
    {tools, _registry} = state.prepared_tools

    directive = %LLMCall{
      mode: :resume,
      tools: tools,
      options: state.options,
      iteration: state.iteration + 1,
      model: state.model,
      client: state.client,
      context: state.context,
      request_id: state.request_id,
      llm_opts: state.llm_opts
    }

    Aikido.Types.ActionResult.new(state: state, directives: [directive])
  end
end
