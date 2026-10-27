defmodule AgentExamples.ResilientAssistantClientTest do
  use ExUnit.Case, async: true

  alias AgentExamples.ResilientAssistant.Client
  alias Aikido.AiReact.Types.ToolCycleWarning

  test "ordinary user messages remain scenario inputs without valid warning metadata" do
    valid = %{request_id: "run", iteration: 3, period: 1, repetitions: 3}

    for payload <- [
          nil,
          "not a map",
          [],
          %{},
          Map.delete(valid, :request_id),
          %{valid | iteration: -1},
          %{valid | period: 5},
          %{valid | repetitions: 4}
        ],
        key <- [:aikido_tool_cycle_warning, "aikido_tool_cycle_warning"] do
      messages = [
        ReqLLM.Context.user("errors"),
        ReqLLM.Context.user("retry", %{key => payload})
      ]

      assert {:error, :timeout} = Client.generate_text("offline", messages, [])
    end

    assert {:error, :timeout} =
             Client.generate_text("offline", [ReqLLM.Context.user("retry")], [])
  end

  test "a valid native warning does not replace the authored scenario input" do
    warning = ToolCycleWarning.new!(request_id: "run", iteration: 3, period: 1, repetitions: 3)
    assert {:ok, constraints} = Ash.Type.init(ToolCycleWarning, [])
    assert {:ok, payload} = Ash.Type.dump_to_embedded(ToolCycleWarning, warning, constraints)

    for key <- [:aikido_tool_cycle_warning, "aikido_tool_cycle_warning"] do
      messages = [
        ReqLLM.Context.user("errors"),
        ReqLLM.Context.user("retry", %{key => payload})
      ]

      assert {:ok, response} = Client.generate_text("offline", messages, [])
      assert [call] = response.message.tool_calls
      assert call.function.name == "fail_example"
    end
  end
end
