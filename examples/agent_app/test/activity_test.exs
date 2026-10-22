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
    assert activity.tools == [%{name: "delegate", finished?: false}]

    answered =
      ReqLLM.Context.append(context, ReqLLM.Context.tool_result("call-1", "delegate", "Done"))

    state = %{state | context: answered, pending_tool_calls: []}
    assert AgentExamples.AI.Activity.from_state(state).stage == "Waiting for model response"

    assert AgentExamples.AI.Activity.from_state(state).tools == [
             %{name: "delegate", finished?: true}
           ]

    assert AgentExamples.AI.Activity.from_state(%{state | status: :setup}).stage ==
             "Preparing tools"

    assert AgentExamples.AI.Activity.from_state(%{state | status: :waiting}).stage ==
             "Waiting for tracked work"

    assert AgentExamples.AI.Activity.from_state(
             Map.merge(state, %{status: :completed, result: "Verified"})
           ).output == "Verified"
  end
end
