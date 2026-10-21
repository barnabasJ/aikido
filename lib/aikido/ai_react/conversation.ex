defmodule Aikido.AiReact.Conversation do
  @moduledoc """
  Maintains ReAct conversation history together with its cached token counts.

  Appending messages updates only their token cost; replacing history refreshes
  the full estimate. Interrupted tool calls receive matching error results so
  the next request contains valid model history. Provider usage counts and
  estimated input size live here because both describe this conversation.
  """

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  # Code/JSON/paths tokenize at ~3 chars/token vs ~4 for prose
  @chars_per_token 3
  # Overhead per message for role markers, special tokens, JSON framing
  @entry_overhead_tokens 10
  # Base overhead for tool/function definitions sent with every API call
  @base_overhead_tokens 300

  # --- Token Estimation ---

  @doc """
  Estimate total token count for a context (all messages + base overhead).

  Because `ReqLLM.Context` represents the system prompt as a regular `:system`
  message, we just walk every message — there is no separate `system_prompt`
  field to account for.
  """
  @spec estimate_tokens(context :: Context.t()) :: non_neg_integer()
  def estimate_tokens(%Context{messages: messages}) do
    message_tokens = messages |> Enum.map(&estimate_message_tokens/1) |> Enum.sum()
    message_tokens + @base_overhead_tokens
  end

  @doc "Replace model context and refresh its cached estimate; prior provider counts no longer apply."
  def replace_context(state, context) do
    Map.merge(state, %{
      context: context,
      estimated_tokens: if(context, do: estimate_tokens(context), else: 0),
      last_input_tokens: nil
    })
  end

  @doc "Append one message and count only that message against the cached estimate."
  def append_message(state, %Message{} = message) do
    tokens =
      case Map.get(state, :estimated_tokens) do
        tokens when is_integer(tokens) and tokens >= @base_overhead_tokens -> tokens
        _ -> estimate_tokens(state.context)
      end

    Map.merge(state, %{
      context: Context.append(state.context, message),
      estimated_tokens: tokens + estimate_message_tokens(message)
    })
  end

  @doc "Append messages in order, updating the estimate for each new message."
  def append_messages(state, messages),
    do: Enum.reduce(messages, state, fn message, state -> append_message(state, message) end)

  @doc """
  Estimate token count for a single message.
  """
  @spec estimate_message_tokens(message :: Message.t()) :: non_neg_integer()
  def estimate_message_tokens(%Message{} = message) do
    content_tokens = estimate_content_tokens(message.content)
    tool_calls_tokens = estimate_tool_calls_tokens(message.tool_calls)
    name_tokens = estimate_string_tokens(message.name)
    id_tokens = estimate_string_tokens(message.tool_call_id)

    content_tokens + tool_calls_tokens + name_tokens + id_tokens + @entry_overhead_tokens
  end

  @doc "Use the greater of the cached conversation estimate and the last provider input count."
  def input_token_count(state),
    do: max(Map.get(state, :last_input_tokens) || 0, Map.get(state, :estimated_tokens, 0))

  @doc "Read a positive input-token count from native provider usage metadata."
  def provider_input_tokens(usage) when is_map(usage) do
    case usage[:input_tokens] || usage["input_tokens"] do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  def provider_input_tokens(_), do: nil

  defp estimate_string_tokens(nil), do: 0

  defp estimate_string_tokens(text) when is_binary(text),
    do: div(byte_size(text), @chars_per_token)

  defp estimate_content_tokens(nil), do: 0

  defp estimate_content_tokens(parts) when is_list(parts) do
    Enum.reduce(parts, 0, fn part, acc ->
      acc + estimate_content_part_tokens(part)
    end)
  end

  defp estimate_content_part_tokens(%ContentPart{type: type, text: text})
       when type in [:text, :thinking] and is_binary(text) do
    div(byte_size(text), @chars_per_token)
  end

  defp estimate_content_part_tokens(%ContentPart{}), do: 0

  defp estimate_content_part_tokens(_), do: 0

  defp estimate_tool_calls_tokens(nil), do: 0
  defp estimate_tool_calls_tokens([]), do: 0

  defp estimate_tool_calls_tokens(tool_calls) when is_list(tool_calls) do
    Enum.reduce(tool_calls, 0, fn tc, acc ->
      acc + estimate_tool_call_tokens(tc) + @entry_overhead_tokens
    end)
  end

  defp estimate_tool_call_tokens(%ToolCall{function: %{name: name, arguments: args}}) do
    name_tokens = estimate_string_tokens(name)
    args_tokens = estimate_string_tokens(args_to_json(args))
    name_tokens + args_tokens
  end

  defp estimate_tool_call_tokens(tc) when is_map(tc) do
    name = data_value(tc, :name)
    args = data_value(tc, :arguments)
    name_tokens = estimate_string_tokens(name)
    args_tokens = estimate_string_tokens(args_to_json(args))
    name_tokens + args_tokens
  end

  defp estimate_tool_call_tokens(_), do: 0

  defp args_to_json(nil), do: nil
  defp args_to_json(args) when is_binary(args), do: args
  defp args_to_json(args), do: Jason.encode!(args)

  @doc "Close an interrupted final tool batch so the next user turn has valid history."
  def append_interrupted_tool_results(context) do
    # Builtins are provider observations; exclude them only from pending-call detection.
    context.messages
    |> Enum.map(fn
      %{role: :assistant, tool_calls: calls} = message when is_list(calls) ->
        %{message | tool_calls: Enum.reject(calls, &ToolCall.builtin?/1)}

      message ->
        message
    end)
    |> AshAi.ToolLoop.pending_tool_calls()
    |> Enum.reduce(context, fn call, context ->
      Context.append(
        context,
        Context.tool_result(
          call.id,
          call.name,
          Jason.encode!(%{error: "interrupted before a result was recorded"})
        )
      )
    end)
  end

  defp data_value(data, key), do: Map.get(data, key, Map.get(data, to_string(key)))
end
