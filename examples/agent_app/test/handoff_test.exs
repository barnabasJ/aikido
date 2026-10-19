defmodule AgentExamples.HandoffTest do
  use ExUnit.Case, async: true

  test "the offline streaming client supports a non-streaming handoff document" do
    messages = [
      ReqLLM.Context.system("Keep the procedure."),
      ReqLLM.Context.user("Continue the work."),
      ReqLLM.Context.user(Aikido.AI.Handoff.instructions())
    ]

    assert {:ok, %Aikido.Slices.AiReact.Turn{type: :final_answer, text: document}} =
             AgentExamples.AI.StreamingClient.generate_text("offline", messages, tools: [])

    assert document =~ "Offline handoff demonstration"
    assert document =~ "Next action:"
  end
end
