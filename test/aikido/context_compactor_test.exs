defmodule Aikido.AI.ContextCompactorTest do
  use ExUnit.Case, async: true

  alias Aikido.AI.ContextCompactor
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

  # Generate a string of approximately `token_count` tokens (chars/3)
  defp token_string(token_count), do: String.duplicate("x", token_count * 3)

  # --- Token Estimation Tests ---

  describe "estimate_tokens/1" do
    test "empty context returns base overhead only" do
      context = make_context()
      # No messages, just the base overhead for tool definitions.
      assert ContextCompactor.estimate_tokens(context) == 300
    end

    test "context with system prompt only" do
      context = make_context(system_prompt: "Hello world!")
      # system msg: 12 chars text content / 3 = 4 + entry overhead 10 = 14
      # + base overhead 300 = 314
      assert ContextCompactor.estimate_tokens(context) == 314
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
      assert ContextCompactor.estimate_tokens(context) == 333
    end

    test "message with thinking content contributes to tokens" do
      msg = assistant_msg(nil, thinking: "I need to think about this carefully to solve it.")

      tokens = ContextCompactor.estimate_message_tokens(msg)
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

      tokens = ContextCompactor.estimate_message_tokens(msg)
      # has the entry overhead + tool calls overhead + name + args, should be > 4
      assert tokens > 4
    end
  end

  # --- Message Grouping Tests ---

  describe "group_messages/1" do
    test "empty messages returns empty groups" do
      assert ContextCompactor.group_messages([]) == []
    end

    test "standalone messages form individual groups" do
      messages = [
        user_msg("hi"),
        assistant_msg("hello"),
        user_msg("bye")
      ]

      groups = ContextCompactor.group_messages(messages)

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

      groups = ContextCompactor.group_messages(messages)

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

      groups = ContextCompactor.group_messages(messages)

      assert [_] = groups
      assert match?([_, _, _], hd(groups))
    end
  end

  # --- check_budget Tests ---

  describe "check_budget/2" do
    test "halts when under budget" do
      context = make_context(messages: [user_msg("hi")])

      assert {:halt, ^context, meta} =
               ContextCompactor.check_budget(context, %{max_tokens: 100_000})

      assert meta.reason == :under_budget
    end

    test "continues when over budget" do
      context = make_context(messages: [user_msg(token_string(100))])

      assert {:cont, ^context, meta} =
               ContextCompactor.check_budget(context, %{max_tokens: 10})

      assert is_integer(meta.estimated_tokens)
    end

    test "halts when no max_tokens configured" do
      context = make_context()

      assert {:halt, ^context, meta} =
               ContextCompactor.check_budget(context, %{})

      assert meta.reason == :no_max_tokens
    end

    test "uses current_tokens from opts when available (LLM-reported)" do
      context = make_context(messages: [user_msg("hi")])

      assert {:halt, ^context, _meta} =
               ContextCompactor.check_budget(context, %{max_tokens: 100_000})

      assert {:cont, ^context, meta} =
               ContextCompactor.check_budget(context, %{
                 max_tokens: 100_000,
                 current_tokens: 200_000
               })

      assert meta.estimated_tokens == 200_000
    end
  end

  # --- prune_tool_outputs Tests ---

  describe "prune_tool_outputs/2" do
    test "prunes old tool messages beyond protection window" do
      big_tool_content = token_string(500)

      messages = [
        user_msg("start"),
        assistant_msg("ok", tool_calls: [make_tool_call("tc1", "exec")]),
        tool_msg("tc1", "exec", big_tool_content),
        user_msg("next"),
        assistant_msg("done")
      ]

      context = make_context(messages: messages)

      {:cont, compacted, meta} =
        ContextCompactor.prune_tool_outputs(context, %{protect_recent_tokens: 100})

      tool_messages = Enum.filter(compacted.messages, &(&1.role == :tool))
      assert [_] = tool_messages
      pruned_text = hd(hd(tool_messages).content).text
      assert pruned_text =~ "[output truncated"
      assert pruned_text =~ "chars]"
      assert meta.pruned_tool_entries == 1
    end

    test "recent tool messages are protected" do
      messages = [
        user_msg("do it"),
        assistant_msg("ok", tool_calls: [make_tool_call("tc1", "exec")]),
        tool_msg("tc1", "exec", "small result")
      ]

      context = make_context(messages: messages)

      {:cont, compacted, meta} =
        ContextCompactor.prune_tool_outputs(context, %{protect_recent_tokens: 100_000})

      tool_messages = Enum.filter(compacted.messages, &(&1.role == :tool))
      assert hd(hd(tool_messages).content).text == "small result"
      assert meta.pruned_tool_entries == 0
    end

    test "non-tool messages are never pruned" do
      messages = [
        user_msg(token_string(500)),
        assistant_msg(token_string(500))
      ]

      context = make_context(messages: messages)

      {:cont, compacted, _meta} =
        ContextCompactor.prune_tool_outputs(context, %{protect_recent_tokens: 10})

      user_messages = Enum.filter(compacted.messages, &(&1.role == :user))
      assert byte_size(hd(hd(user_messages).content).text) == 500 * 3
    end
  end

  # --- slide_window Tests ---

  describe "slide_window/2" do
    test "drops oldest groups to fit within budget" do
      messages = [
        user_msg(token_string(100)),
        assistant_msg(token_string(100)),
        user_msg(token_string(100)),
        assistant_msg(token_string(100))
      ]

      context = make_context(messages: messages)

      {:cont, compacted, meta} =
        ContextCompactor.slide_window(context, %{max_tokens: 250})

      assert length(compacted.messages) < length(context.messages)
      assert meta.dropped_entries > 0
    end

    test "always keeps most recent group" do
      messages = [
        user_msg(token_string(1000)),
        assistant_msg(token_string(1000))
      ]

      context = make_context(messages: messages)

      {:cont, compacted, _meta} =
        ContextCompactor.slide_window(context, %{max_tokens: 10})

      assert compacted.messages != []
    end

    test "nil max_tokens is a no-op" do
      context = make_context(messages: [user_msg("hi")])

      {:cont, compacted, _meta} =
        ContextCompactor.slide_window(context, %{})

      assert compacted.messages == context.messages
    end

    test "empty context is a no-op" do
      context = make_context()

      {:cont, compacted, _meta} =
        ContextCompactor.slide_window(context, %{max_tokens: 100})

      assert compacted.messages == []
    end

    test "single group context is preserved" do
      context = make_context(messages: [user_msg(token_string(500))])

      {:cont, compacted, _meta} =
        ContextCompactor.slide_window(context, %{max_tokens: 10})

      assert match?([_], compacted.messages)
    end
  end

  # --- Pipeline Composition Tests ---

  describe "run/3 pipeline" do
    test "full default pipeline on large context" do
      big_output = token_string(10_000)

      messages = [
        user_msg("first task"),
        assistant_msg("ok", tool_calls: [make_tool_call("tc1", "exec")]),
        tool_msg("tc1", "exec", big_output),
        user_msg("second task"),
        assistant_msg("ok", tool_calls: [make_tool_call("tc2", "exec")]),
        tool_msg("tc2", "exec", big_output),
        user_msg("third task"),
        assistant_msg("done")
      ]

      context = make_context(messages: messages)

      opts = %{
        max_tokens: 1_000,
        protect_recent_tokens: 500
      }

      {compacted, meta} = ContextCompactor.run(context, ContextCompactor.default_steps(), opts)

      assert ContextCompactor.estimate_tokens(compacted) <
               ContextCompactor.estimate_tokens(context)

      assert is_map(meta)
    end

    test "pipeline halts early when under budget" do
      context = make_context(messages: [user_msg("hi")])

      opts = %{max_tokens: 100_000}

      {compacted, meta} = ContextCompactor.run(context, ContextCompactor.default_steps(), opts)

      assert compacted.messages == context.messages
      assert meta.reason == :under_budget
    end

    test "step failure is caught and skipped (fail-open)" do
      failing_step = fn _context, _opts ->
        raise "kaboom"
      end

      context = make_context(messages: [user_msg("hi")])

      {compacted, meta} = ContextCompactor.run(context, [failing_step], %{})
      assert compacted.messages == context.messages
      assert meta.error == "kaboom"
    end

    test "custom step list" do
      custom_step = fn context, opts ->
        {:cont, context, Map.put(opts, :custom_ran, true)}
      end

      context = make_context(messages: [user_msg("hi")])

      {_compacted, meta} = ContextCompactor.run(context, [custom_step], %{})

      assert meta.custom_ran == true
    end
  end
end
