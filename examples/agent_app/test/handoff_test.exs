defmodule AgentExamples.HandoffTest do
  use ExUnit.Case, async: true

  test "the offline streaming client supports a non-streaming handoff document" do
    messages = [
      ReqLLM.Context.system("Keep the procedure."),
      ReqLLM.Context.user("Continue the work."),
      ReqLLM.Context.user(Aikido.AiReact.ConversationHandoff.instructions())
    ]

    assert {:ok, response} =
             AgentExamples.AI.StreamingClient.generate_text("offline", messages, tools: [])

    document = ReqLLM.Response.text(response)
    assert document =~ "Offline handoff demonstration"
    assert document =~ "Next action:"
  end
end
