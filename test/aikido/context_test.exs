defmodule Aikido.AI.ContextTest do
  use ExUnit.Case, async: true

  alias Aikido.AI.Context, as: Conversation
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

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

  # --- Message Grouping Tests ---

  describe "group_messages/1" do
    test "empty messages returns empty groups" do
      assert Conversation.group_messages([]) == []
    end

    test "standalone messages form individual groups" do
      messages = [
        user_msg("hi"),
        assistant_msg("hello"),
        user_msg("bye")
      ]

      groups = Conversation.group_messages(messages)

      assert [_, _, _] = groups
      assert Enum.all?(groups, &match?([_], &1))

      [[first], [second], [third]] = groups
      assert hd(first.content).text == "hi"
      assert hd(second.content).text == "hello"
      assert hd(third.content).text == "bye"
    end

    test "assistant with tool_calls grouped with tool results" do
      tc = [make_tool_call("tc1", "execute")]

      messages = [
        user_msg("do something"),
        assistant_msg("ok", tool_calls: tc),
        tool_msg("tc1", "execute", "done"),
        assistant_msg("finished")
      ]

      groups = Conversation.group_messages(messages)

      assert [_, _, _] = groups

      # First group: user message
      assert match?([_], Enum.at(groups, 0))

      # Second group: assistant + tool result
      group2 = Enum.at(groups, 1)
      assert [_, _] = group2
      assert hd(group2).role == :assistant
      assert List.last(group2).role == :tool

      # Third group: standalone assistant
      assert match?([_], Enum.at(groups, 2))
    end

    test "multiple tool calls grouped together" do
      tc = [make_tool_call("tc1", "read"), make_tool_call("tc2", "write")]

      messages = [
        assistant_msg("running", tool_calls: tc),
        tool_msg("tc1", "read", "content"),
        tool_msg("tc2", "write", "ok")
      ]

      groups = Conversation.group_messages(messages)

      assert [_] = groups
      assert match?([_, _, _], hd(groups))
    end
  end
end
