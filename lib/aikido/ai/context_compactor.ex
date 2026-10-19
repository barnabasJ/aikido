defmodule Aikido.AI.ContextCompactor do
  @moduledoc """
  Pipeline-based context compaction for coding agent threads.

  Long threads accumulate unbounded message history in `ReqLLM.Context`.
  This module provides a pipeline of transformers that prune tool outputs and
  slide the context window before each LLM call, keeping threads within
  safe token bounds.

  ## Pipeline

  Each transformer receives `(context, opts)` and returns one of:
  - `{:cont, context, metadata}` — continue to next step
  - `{:halt, context, metadata}` — stop pipeline early (e.g., already under budget)

  The default pipeline runs three steps in order:
  1. **check_budget** — halt early if estimated tokens are already under `max_tokens`
  2. **prune_tool_outputs** — replace old tool result content with truncation markers
  3. **slide_window** — drop oldest message groups until within budget

  ## Token Estimation

  Uses a chars/3 heuristic (1 token ~= 3 characters) for fast estimation without
  requiring a tokenizer dependency, plus fixed overhead for tool definitions and
  message framing. Sufficient for budget-gating decisions.

  ## Message Storage Order

  `ReqLLM.Context` stores messages chronologically (oldest first); the most
  recent message is at the end of the list. Grouping and sliding logic in this
  module operates on that chronological order — the newest group lives at the
  tail.
  """

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  @type transformer ::
          (Context.t(), map() -> {:cont, Context.t(), map()} | {:halt, Context.t(), map()})

  # Code/JSON/paths tokenize at ~3 chars/token vs ~4 for prose
  @chars_per_token 3
  # Overhead per message for role markers, special tokens, JSON framing
  @entry_overhead_tokens 10
  # Base overhead for tool/function definitions sent with every API call
  @base_overhead_tokens 300

  # --- Pipeline Runner ---

  @doc """
  Run a pipeline of transformer steps on a context.

  Returns `{context, metadata}` where metadata accumulates information from each step.
  Steps that raise are skipped and their error is returned in metadata; no I/O is performed.
  """
  @spec run(context :: Context.t(), steps :: [transformer()], opts :: map()) ::
          {Context.t(), map()}
  def run(%Context{} = context, steps, opts \\ %{}) do
    Enum.reduce_while(steps, {context, opts}, fn step, {context_acc, meta_acc} ->
      try do
        case step.(context_acc, meta_acc) do
          {:cont, new_context, new_meta} ->
            {:cont, {new_context, new_meta}}

          {:halt, new_context, new_meta} ->
            {:halt, {new_context, new_meta}}
        end
      rescue
        e ->
          {:cont, {context_acc, Map.put(meta_acc, :error, Exception.message(e))}}
      end
    end)
  end

  @doc """
  Returns the default compaction pipeline steps.
  """
  @spec default_steps() :: [transformer()]
  def default_steps do
    [&check_budget/2, &prune_tool_outputs/2, &slide_window/2]
  end

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

  # --- Built-in Transformers ---

  @doc """
  Check if the context is already under budget. If so, halt the pipeline.
  """
  @spec check_budget(context :: Context.t(), opts :: map()) ::
          {:cont, Context.t(), map()} | {:halt, Context.t(), map()}
  def check_budget(%Context{} = context, opts) do
    max_tokens = Map.get(opts, :max_tokens)

    if is_nil(max_tokens) do
      {:halt, context, Map.put(opts, :reason, :no_max_tokens)}
    else
      # Prefer LLM-reported token count when available (passed via :current_tokens).
      # Falls back to chars/3 heuristic which underestimates due to not accounting
      # for system prompt overhead, function definitions, and message formatting.
      estimated = Map.get(opts, :current_tokens) || estimate_tokens(context)

      if estimated < max_tokens do
        {:halt, context, Map.put(opts, :reason, :under_budget)}
      else
        {:cont, context, Map.put(opts, :estimated_tokens, estimated)}
      end
    end
  end

  @doc """
  Replace content of old tool result messages with a truncation marker.

  Messages within the `protect_recent_tokens` window (counting from newest)
  are preserved. Only `:tool` role messages outside the protected window are
  pruned. Each `ContentPart` on a pruned tool message has its `text` replaced
  with `"[output truncated — N chars]"` where N is the byte size of the
  original text.
  """
  @spec prune_tool_outputs(context :: Context.t(), opts :: map()) :: {:cont, Context.t(), map()}
  def prune_tool_outputs(%Context{messages: messages} = context, opts) do
    protect_recent = Map.get(opts, :protect_recent_tokens, 40_000)

    # Walk newest-first (reverse of chronological storage). Accumulate tokens.
    # Once past the protect window, prune `:tool` messages.
    {pruned_reversed, {_running_tokens, pruned_count}} =
      messages
      |> Enum.reverse()
      |> Enum.map_reduce({0, 0}, fn message, {running_tokens, pruned} ->
        message_tokens = estimate_message_tokens(message)
        new_running = running_tokens + message_tokens
        maybe_prune_message(message, new_running, protect_recent, pruned)
      end)

    pruned_messages = Enum.reverse(pruned_reversed)

    {:cont, %{context | messages: pruned_messages},
     Map.put(opts, :pruned_tool_entries, pruned_count)}
  end

  @doc """
  Drop oldest message groups until remaining messages fit within `max_tokens`.

  Always keeps at least the most recent group. Groups are atomic — an assistant
  message with tool_calls and its tool results are dropped together.
  """
  @spec slide_window(context :: Context.t(), opts :: map()) ::
          {:cont, Context.t(), map()} | {:halt, Context.t(), map()}
  def slide_window(%Context{messages: messages} = context, opts) do
    max_tokens = Map.get(opts, :max_tokens)

    if is_nil(max_tokens) do
      {:cont, context, opts}
    else
      groups = group_messages(messages)

      case groups do
        [] ->
          {:cont, context, opts}

        [_single] ->
          {:cont, context, opts}

        groups ->
          slide_groups(context, groups, max_tokens, opts)
      end
    end
  end

  # Groups are chronological (oldest first, newest last). Keep the newest
  # groups that fit within budget by walking from newest to oldest, accumulating
  # tokens. Always keep the newest group.
  defp slide_groups(context, groups, max_tokens, opts) do
    [newest | older_reversed] = Enum.reverse(groups)
    newest_tokens = group_tokens(newest) + @base_overhead_tokens

    {kept_groups, _budget} =
      Enum.reduce_while(older_reversed, {[newest], newest_tokens}, fn group, {kept, used} ->
        g_tokens = group_tokens(group)

        if used + g_tokens <= max_tokens do
          {:cont, {[group | kept], used + g_tokens}}
        else
          {:halt, {kept, used}}
        end
      end)

    # kept_groups is in chronological order (we prepended older groups onto
    # an accumulator that already held the newest group).
    new_messages = List.flatten(kept_groups)
    dropped = length(messages_of(context)) - length(new_messages)

    {:cont, %{context | messages: new_messages}, Map.put(opts, :dropped_entries, dropped)}
  end

  defp messages_of(%Context{messages: messages}), do: messages

  defp group_tokens(group), do: group |> Enum.map(&estimate_message_tokens/1) |> Enum.sum()

  # --- Private Helpers ---

  defp maybe_prune_message(message, running_tokens, protect_recent, pruned)
       when running_tokens <= protect_recent or message.role != :tool do
    {message, {running_tokens, pruned}}
  end

  defp maybe_prune_message(%Message{content: content} = message, running_tokens, _protect, pruned) do
    pruned_content = Enum.map(content, &prune_content_part/1)
    {%{message | content: pruned_content}, {running_tokens, pruned + 1}}
  end

  defp prune_content_part(%ContentPart{type: :text, text: text} = part) when is_binary(text) do
    marker = "[output truncated — #{byte_size(text)} chars]"
    %{part | text: marker}
  end

  defp prune_content_part(%ContentPart{} = part) do
    # Non-text parts (image/file/etc) on a tool message — replace with a
    # zero-length marker rather than attempting to measure binary payloads.
    %ContentPart{type: :text, text: "[output truncated — 0 chars]"}
    |> Map.put(:metadata, part.metadata)
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

  @doc "Compact a model context while retaining system instructions and complete tool groups."
  def compact(context, options) do
    options = Aikido.AI.Options.resolve(options)

    if is_nil(options.context_max_tokens) do
      context
    else
      {system, messages} = Enum.split_with(context.messages, &(&1.role == :system))

      steps =
        if options.compaction_steps == [], do: default_steps(), else: options.compaction_steps

      {compacted, _metadata} =
        run(%{context | messages: messages}, steps, %{
          max_tokens:
            max(
              options.context_max_tokens - Enum.sum(Enum.map(system, &estimate_message_tokens/1)),
              1
            ),
          protect_recent_tokens: options.protect_recent_tokens
        })

      %{compacted | messages: system ++ compacted.messages}
    end
  end

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
