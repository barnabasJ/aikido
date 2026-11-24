defmodule Aikido.AiReact.Actions.HandoffCompleted do
  @moduledoc "Adopts a validated handoff document, retains usage and resumes the next model turn."
  use Ash.Resource.Actions.Implementation

  alias Aikido.AiReact.Conversation
  alias Aikido.AiReact.{ConversationHandoff, HookQueue}
  alias Aikido.AiReact.Directives.LLMCall

  @impl true
  def run(input, _opts, _context) do
    with {:ok, state, directives} <- process_handoff_document(input) do
      changes =
        if state == input.arguments.state,
          do: %{},
          else: Map.take(state, Enum.map(Ash.Resource.Info.attributes(input.resource), & &1.name))

      Aikido.Types.ActionResult.new(
        changes: changes,
        directives: directives,
        outputs: Aikido.AiReact.Conversation.accepted_output(state)
      )
    end
  end

  defp process_handoff_document(input) do
    input.arguments.state
    |> adopt_handoff_and_resume(Map.delete(input.arguments, :state))
  end

  @doc false
  def adopt_handoff_and_resume(state, data) do
    if ConversationHandoff.active?(state, data) do
      turn = ReqLLM.Response.classify(data.turn)

      state =
        state
        |> accumulate_usage(data.turn)
        |> Map.put(:handoff_response, response_classification(data.turn, turn))

      with {:ok, document} <- extract_handoff_document(turn),
           replacement = replace_conversation(state, document),
           :ok <- check_context_capacity(replacement) do
        replacement
        |> record_handoff(state, data.handoff_id, document)
        |> request_resumed_model_turn()
        |> HookQueue.queue_event_hooks(:after_model, %{handoff: true})
      else
        {:error, reason} ->
          case ConversationHandoff.regenerate_document(state, reason) do
            :exhausted ->
              Aikido.AiReact.Actions.HandoffFailed.fail_pending_handoff(
                state,
                Map.put(data, :reason, reason)
              )

            result ->
              result
          end
      end
    else
      {:ok, state, []}
    end
  end

  defp extract_handoff_document(turn) do
    cond do
      turn.finish_reason == :error ->
        {:error, :response_error}

      turn.finish_reason == :length ->
        {:error, :truncated_document}

      turn.type != :final_answer || String.trim(turn.text) == "" ->
        {:error, :empty_or_invalid_document}

      true ->
        {:ok, String.trim(turn.text)}
    end
  end

  defp response_classification(response, turn) do
    %{
      type: turn.type,
      finish_reason: turn.finish_reason,
      text_bytes: byte_size(turn.text),
      tool_call_count: length(turn.tool_calls),
      model: response.model && String.slice(response.model, 0, 256)
    }
    |> Map.merge(response_error_classification(response))
  end

  defp response_error_classification(%{provider_meta: %{"error" => details}}) do
    constraints =
      Ash.Resource.Info.attribute(Aikido.AiReact.Slice, :handoff_response).constraints[:fields][
        :error
      ][:constraints]

    with {:ok, error} <- Ash.Type.cast_input(:map, details, constraints),
         {:ok, error} <- Ash.Type.apply_constraints(:map, error, constraints) do
      %{error: error}
    else
      _ -> %{}
    end
  end

  defp response_error_classification(_response), do: %{}

  defp replace_conversation(state, document) do
    system = Enum.filter(state.context.messages, &(&1.role == :system))

    # The takeover is an EXPLICIT accepted entry (never a context construction
    # outside the seam): the window after the replacement restart is
    # [takeover, carried replay...] — including the EMPTY-carry case, where
    # the window is exactly [takeover]. Replayed carry is genuine transcript;
    # internal todo prompts are excluded by their marker upstream.
    takeover =
      ReqLLM.Context.user("""
      You are taking over mid-run. Your predecessor left this handoff:

      #{document}

      Continue from the next action.\
      """)

    carry = state.opening_messages ++ state.queued_messages

    state
    |> Conversation.replace_context(ReqLLM.Context.new(system))
    |> Conversation.append_messages([takeover] ++ Enum.map(carry, &ReqLLM.Context.user/1))
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
      opening_messages: original.opening_messages ++ original.queued_messages,
      queued_messages: [],
      todo_idle_reminder:
        if(original.queued_messages == [],
          do: Map.get(replacement, :todo_idle_reminder),
          else: nil
        ),
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
      deadline_at: Map.get(state, :deadline_at),
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

    {:ok, state, [directive]}
  end
end
