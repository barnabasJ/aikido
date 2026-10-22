defmodule AgentExamples.AI.ActivityTest do
  use ExUnit.Case, async: true

  test "distinguishes tool preparation, model work, pending results and completion" do
    call = ReqLLM.ToolCall.new("call-1", "delegate", ~s({"member":"analyst"}))
    context = ReqLLM.Context.new([ReqLLM.Context.user("Review the evidence")])
    context = ReqLLM.Context.append(context, ReqLLM.Context.assistant("", tool_calls: [call]))

    state = %{
      status: :running,
      context: context,
      iteration: 2,
      pending_tool_calls: [%{id: "call-1"}]
    }

    activity = AgentExamples.AI.Activity.from_state(state)
    assert activity.task == "Review the evidence"
    assert activity.stage == "Tool calls pending"
    assert [%{name: "delegate", status: :pending, input: input}] = activity.tools
    assert input =~ "analyst"

    answered =
      ReqLLM.Context.append(context, ReqLLM.Context.tool_result("call-1", "delegate", "Done"))

    state = %{state | context: answered, pending_tool_calls: []}
    assert AgentExamples.AI.Activity.from_state(state).stage == "Waiting for model response"

    assert [%{name: "delegate", status: :completed}] =
             AgentExamples.AI.Activity.from_state(state).tools

    assert AgentExamples.AI.Activity.from_state(%{state | status: :setup}).stage ==
             "Preparing tools"

    assert AgentExamples.AI.Activity.from_state(%{state | status: :waiting}).stage ==
             "Waiting for tracked work"

    assert AgentExamples.AI.Activity.from_state(
             Map.merge(state, %{status: :completed, result: "Verified"})
           ).output == "Verified"
  end

  test "failed tool results stay visible even when the model completes its answer" do
    call =
      ReqLLM.ToolCall.new(
        "failed",
        "run_lua",
        ~s|{"input":{"script":"return agents.members({})"}}|
      )

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.user("Inspect the team"),
        ReqLLM.Context.assistant("", tool_calls: [call]),
        ReqLLM.Context.tool_result(
          "failed",
          "run_lua",
          ~s({"error":{"message":"Worker already exists"}})
        )
      ])

    assert [%{label: "Run Lua script", status: :failed, input: "return agents.members({})"}] =
             AgentExamples.AI.Activity.from_state(%{status: :completed, context: context}).tools
  end
end
