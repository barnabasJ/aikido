defmodule AgentExamples.DemoTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  test "the command-line state examples execute through native domain commands and clean up" do
    output = capture_io(fn -> assert :ok = AgentExamples.Demo.run() end)
    assert output =~ "SIGNALS CARRY RESULTS"
    assert output =~ "Team counter (started at 10): 15"

    refute Enum.any?(AgentExamples.Agents.counter_list!(), &(&1.id == "demo-counter"))
    refute Enum.any?(AgentExamples.Agents.team_list!(), &(&1.id == "demo-team"))
  end

  test "the command-line AI example inspects the dynamically created squad hierarchy" do
    output = capture_io(fn -> assert :ok = AgentExamples.AI.Demo.run() end)
    assert output =~ "Words: 3"
    assert output =~ "investigation"
    assert output =~ "verification"
    assert output =~ "focused-research"
    assert output =~ ~s(Helper's owner: "researcher")
  end
end
