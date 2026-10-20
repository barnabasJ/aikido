defmodule Aikido.AI.ContextTest do
  use ExUnit.Case, async: true

  alias Aikido.Slices.AiReact.Context, as: Conversation
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  test "incremental estimates match a full count through user, assistant and tool messages" do
    state =
      Conversation.replace_context(%{}, Context.new([Context.system("Keep the procedure.")]))

    calls = [%{id: "one", name: "lookup", arguments: %{query: "a search"}}]

    messages = [
      Context.user("Start here."),
      Context.assistant("I will look it up.", tool_calls: calls),
      Context.tool_result("one", "lookup", "Some evidence."),
      Context.user("Also consider this follow-up."),
      Context.assistant("The conclusion.")
    ]

    Enum.reduce(messages, state, fn message, state ->
      updated = Conversation.append_message(state, message)
      assert updated.estimated_tokens == Conversation.estimate_tokens(updated.context)

      assert updated.estimated_tokens ==
               state.estimated_tokens + Conversation.estimate_message_tokens(message)

      updated
    end)
  end

  test "appending trusts the cached estimate and counts only the new message" do
    state = %{context: Context.new([Context.user("earlier")]), estimated_tokens: 10_000}
    message = Context.user("new message")
    updated = Conversation.append_message(state, message)
    assert updated.estimated_tokens == 10_000 + Conversation.estimate_message_tokens(message)
  end

  test "replacement refreshes an old estimate and invalidates the old provider count" do
    state = %{
      context: Context.new([Context.user("old")]),
      estimated_tokens: 999_999,
      last_input_tokens: 888_888
    }

    context = Context.new([Context.system("new procedure"), Context.user("new task")])
    replaced = Conversation.replace_context(state, context)
    assert replaced.estimated_tokens == Conversation.estimate_tokens(context)
    assert replaced.last_input_tokens == nil
    assert Conversation.replace_context(replaced, nil).estimated_tokens == 0
  end

  test "handoff threshold reads cached counts without examining the conversation" do
    state = %{
      context: Context.new([Context.user("earlier")]),
      estimated_tokens: 1_234,
      last_input_tokens: 987
    }

    assert Aikido.Slices.AiReact.Handoff.current_tokens(state) == 1_234

    assert Aikido.Slices.AiReact.Handoff.current_tokens(%{state | last_input_tokens: 1_500}) ==
             1_500
  end

  # --- Helpers ---

  # Build a chronological ReqLLM.Context from a list of messages. If
  # `system_prompt:` is given it is prepended as the first :system message —
  # ReqLLM.Context has no separate `system_prompt` field; the system message
  # lives in the regular messages list.
  defp make_context(opts \\ []) do
    messages = Keyword.get(opts, :messages, [])
    system_prompt = Keyword.get(opts, :system_prompt)

    messages =
      if system_prompt do
        [system_msg(system_prompt) | messages]
      else
        messages
      end

    %Context{messages: messages, tools: []}
  end

  defp system_msg(text) do
    %Message{role: :system, content: [ContentPart.text(text)]}
  end

  defp user_msg(content) do
    %Message{role: :user, content: [ContentPart.text(content)]}
  end

  defp assistant_msg(content, opts \\ []) do
    tool_calls = Keyword.get(opts, :tool_calls)
    thinking = Keyword.get(opts, :thinking)

    parts =
      []
      |> then(fn acc -> if thinking, do: [ContentPart.thinking(thinking) | acc], else: acc end)
      |> then(fn acc ->
        if is_binary(content), do: acc ++ [ContentPart.text(content)], else: acc
      end)

    %Message{
      role: :assistant,
      content: parts,
      tool_calls: tool_calls
    }
  end

  defp tool_msg(tool_call_id, name, content) do
    %Message{
      role: :tool,
      content: [ContentPart.text(content)],
      tool_call_id: tool_call_id,
      name: name
    }
  end

  defp make_tool_call(id, name, args \\ %{}) do
    ToolCall.new(id, name, Jason.encode!(args))
  end

  # --- Token Estimation Tests ---

  describe "estimate_tokens/1" do
    test "empty context returns base overhead only" do
      context = make_context()
      # No messages, just the base overhead for tool definitions.
      assert Conversation.estimate_tokens(context) == 300
    end

    test "context with system prompt only" do
      context = make_context(system_prompt: "Hello world!")
      # system msg: 12 chars text content / 3 = 4 + entry overhead 10 = 14
      # + base overhead 300 = 314
      assert Conversation.estimate_tokens(context) == 314
    end

    test "context with user and assistant messages" do
      context =
        make_context(
          system_prompt: "sys",
          messages: [
            user_msg("hello"),
            assistant_msg("world")
          ]
        )

      # system msg: 3/3 = 1 + 10 = 11
      # user: 5/3 = 1 + 10 = 11
      # assistant: 5/3 = 1 + 10 = 11
      # total = 11 + 11 + 11 + 300 = 333
      assert Conversation.estimate_tokens(context) == 333
    end

    test "message with thinking content contributes to tokens" do
      msg = assistant_msg(nil, thinking: "I need to think about this carefully to solve it.")

      tokens = Conversation.estimate_message_tokens(msg)
      # thinking: 50/3 = 16, + 10 entry overhead = 26
      assert tokens == 26
    end

    test "message with tool_calls estimates argument JSON size" do
      msg =
        assistant_msg("ok",
          tool_calls: [
            make_tool_call("tc1", "execute", %{
              "script" => "agent.file_system.read_file({ input = { path = 'foo.ex' } })"
            })
          ]
        )

      tokens = Conversation.estimate_message_tokens(msg)
      # has the entry overhead + tool calls overhead + name + args, should be > 4
      assert tokens > 4
    end
  end

  test "interruption repair preserves recorded results and closes only missing calls" do
    calls = [make_tool_call("first", "lookup"), make_tool_call("second", "lookup")]
    completed = tool_msg("first", "lookup", "known result")
    original = Context.new([assistant_msg("Checking", tool_calls: calls), completed])
    repaired = Conversation.close_tool_calls(original)
    assert Enum.take(repaired.messages, 2) == original.messages
    assert List.last(repaired.messages).tool_call_id == "second"
    assert Conversation.close_tool_calls(repaired) == repaired
  end
end
