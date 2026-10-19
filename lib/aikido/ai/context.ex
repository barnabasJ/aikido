defmodule Aikido.AI.Context do
  @moduledoc "Lossless conversation helpers: token estimates, tool grouping and interruption repair."

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

  @doc """
  Group context messages into atomic units.

  An assistant message with non-empty `tool_calls` is grouped with the
  subsequent `:tool` messages whose `tool_call_id` matches one of the
  assistant's tool call ids. Standalone messages (user, system, assistant
  without tool_calls) form their own single-message groups.

  Input messages are chronological (oldest first); the returned list of groups
  is also chronological — the newest group is last.
  """
  @spec group_messages(messages :: [Message.t()]) :: [[Message.t()]]
  def group_messages(messages) when is_list(messages) do
    messages
    |> do_group_messages([])
    |> Enum.reverse()
  end

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

  # Tool-call id extraction across the shapes we may encounter
  defp tool_call_id(%ToolCall{id: id}), do: id
  defp tool_call_id(%{id: id}) when is_binary(id), do: id
  defp tool_call_id(%{"id" => id}) when is_binary(id), do: id
  defp tool_call_id(_), do: nil

  # Group messages into atomic units. Input is chronological (oldest first);
  # accumulator collects groups newest-first and is reversed by the caller.
  defp do_group_messages([], acc), do: acc

  defp do_group_messages([%Message{role: :assistant, tool_calls: tc} = message | rest], acc)
       when is_list(tc) and tc != [] do
    tool_call_ids =
      tc
      |> Enum.map(&tool_call_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {tool_results, remaining} =
      Enum.split_while(rest, fn
        %Message{role: :tool, tool_call_id: id} -> MapSet.member?(tool_call_ids, id)
        _ -> false
      end)

    group = [message | tool_results]
    do_group_messages(remaining, [group | acc])
  end

  defp do_group_messages([message | rest], acc) do
    do_group_messages(rest, [[message] | acc])
  end

  defp data_value(data, key), do: Map.get(data, key, Map.get(data, to_string(key)))

  @doc "Close an interrupted final tool batch so the next user turn has valid history."
  def close_tool_calls(context) do
    case context.messages |> group_messages() |> List.last() do
      [%Message{role: :assistant, tool_calls: calls} | results]
      when is_list(calls) and calls != [] ->
        answered = MapSet.new(Enum.map(results, & &1.tool_call_id))

        Enum.reduce(calls, context, fn call, context ->
          id = tool_call_id(call)

          if MapSet.member?(answered, id) do
            context
          else
            name =
              case call do
                %ToolCall{function: function} -> function.name
                map -> data_value(map, :name)
              end

            Context.append(
              context,
              Context.tool_result(
                id,
                name,
                Jason.encode!(%{error: "interrupted before a result was recorded"})
              )
            )
          end
        end)

      _ ->
        context
    end
  end
end
