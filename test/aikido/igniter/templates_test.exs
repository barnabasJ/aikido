defmodule AikidoTest.Igniter.TemplatesTest do
  use ExUnit.Case, async: true

  alias Aikido.Igniter.Templates

  describe "agent_template/3" do
    test "emits a slices do … end block when plugins are provided" do
      template =
        Templates.agent_template(
          "MyApp.Agent",
          "my_agent",
          plugins: [MyApp.PluginOne, MyApp.PluginTwo]
        )

      assert template =~ "slices do"
      assert template =~ "slice :plugin_one, MyApp.PluginOne"
      assert template =~ "slice :plugin_two, MyApp.PluginTwo"
    end
  end

  describe "agent_test_template/2" do
    test "uses module alias name in Info-based assertions" do
      template =
        Templates.agent_test_template("MyApp.Agents.Example", "AikidoTest.Agents.Example")

      assert template =~ "agent = Example.initialize!()"
      assert template =~ "assert agent.name == Map.get(AgentInfo.agent_options(Example), :name)"
    end
  end
end
