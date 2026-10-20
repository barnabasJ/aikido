defmodule Aikido.AI.ContextRepairTest do
  use ExUnit.Case, async: true

  alias Aikido.AI.Context, as: Conversation
  alias Aikido.Slices.AiReact
  alias ReqLLM.{Context, ToolCall}
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  test "builtin-only history retains native content and has no fabricated wire output" do
    context = history([ToolCall.new_builtin("builtin", "web_search", "{}")])

    assert Conversation.close_tool_calls(context) == context
    assert wire_outputs(context) == []

    assert Conversation.close_tool_calls(Context.new()) == Context.new()

    for calls <- [nil, []] do
      no_calls = %{List.last(context.messages) | tool_calls: calls}
      context = %{context | messages: [no_calls]}
      assert Conversation.close_tool_calls(context) == context
    end
  end

  test "mixed calls repair only missing application results and remain idempotent" do
    for builtin <- [
          ToolCall.new_builtin("builtin", "web_search", "{}"),
          %{id: "builtin", function: %{name: "web_search", arguments: "{}", builtin?: true}},
          %{id: "builtin", name: "web_search", arguments: %{}, builtin?: true}
        ] do
      context =
        history([
          builtin,
          ToolCall.new("answered", "lookup", "{}"),
          ToolCall.new("pending", "lookup", "{}")
        ])
        |> Context.append(Context.tool_result("answered", "lookup", "recorded"))

      repaired = Conversation.close_tool_calls(context)
      assert Enum.take(repaired.messages, length(context.messages)) == context.messages
      assert List.last(repaired.messages).tool_call_id == "pending"
      assert List.last(repaired.messages).name == "lookup"

      assert Jason.decode!(hd(List.last(repaired.messages).content).text) == %{
               "error" => "interrupted before a result was recorded"
             }

      assert Conversation.close_tool_calls(repaired) == repaired
      assert Enum.map(wire_outputs(repaired), & &1["call_id"]) == ["answered", "pending"]
    end
  end

  test "next ask and reinstatement preserve completed builtin history" do
    context = history([ToolCall.new_builtin("builtin", "web_search", "{}")])
    state = %{status: :completed, context: context, model: "offline"}

    restored = state |> AiReact.externalize() |> AiReact.reinstate()
    assert restored.status == :completed
    assert restored.context == context
    assert restored.estimated_tokens == Conversation.estimate_tokens(context)
    assert wire_outputs(restored.context) == []

    for prior <- [state, restored] do
      result =
        AiReact
        |> Ash.ActionInput.for_action(
          :ask,
          %{state: prior, query: "continue", request_id: "next"},
          context: %{aikido: %{}}
        )
        |> Ash.run_action!()

      assert result.state.status == :setup
      assert Enum.drop(result.state.context.messages, -1) == context.messages
      assert List.last(result.state.context.messages) == Context.user("continue")
      assert wire_outputs(result.state.context) == []
    end
  end

  defp history(calls) do
    assistant =
      Context.assistant("answer",
        metadata: %{response_id: "native-response", provider: %{opaque: "keep"}}
      )

    assistant = %{
      assistant
      | tool_calls: calls,
        content: [
          ContentPart.thinking("reasoning", %{signature: "signed-content"}),
          ContentPart.text("answer")
        ]
    }

    Context.new([Context.user("question"), assistant])
  end

  defp wire_outputs(context) do
    context
    |> ResponsesAPI.encode_input_items("gpt-5", :openai, false)
    |> Enum.filter(&(&1["type"] == "function_call_output"))
  end
end
