defmodule Aikido.Dsl.AgentTest do
  use ExUnit.Case, async: true

  alias Aikido.Agent
  alias Aikido.Dsl.Agent.Info, as: AgentInfo

  defmodule SimpleAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name "simple_agent"
      description "Bare agent — no plugins, no slices."
      category "test"
      tags ["simple", "test"]
      vsn "1.0.0"
      path :domain

      schema do
        attribute(:counter, :integer, default: 0)
        attribute(:status, :atom, default: :idle)
      end
    end
  end

  describe "basic accessors (sectioned `agent do … end`)" do
    test "name/1" do
      assert Map.get(AgentInfo.agent_options(SimpleAgent), :name) == "simple_agent"
    end

    test "description/1" do
      assert Map.get(AgentInfo.agent_options(SimpleAgent), :description) ==
               "Bare agent — no plugins, no slices."
    end

    test "category/1" do
      assert Map.get(AgentInfo.agent_options(SimpleAgent), :category) == "test"
    end

    test "tags/1" do
      assert Map.get(AgentInfo.agent_options(SimpleAgent), :tags) == ["simple", "test"]
    end

    test "vsn/1" do
      assert Map.get(AgentInfo.agent_options(SimpleAgent), :vsn) == "1.0.0"
    end

    test "path/1" do
      assert Map.get(AgentInfo.agent_options(SimpleAgent), :path) == :domain
    end

    test "slices/1 / middleware/1 default to framework defaults / empty" do
      # Framework default slices are auto-attached.
      assert Aikido.Slices.Memory in AgentInfo.slices(SimpleAgent)
      assert Aikido.Slices.Identity in AgentInfo.slices(SimpleAgent)
      assert Aikido.Slices.Thread in AgentInfo.slices(SimpleAgent)
      assert AgentInfo.middleware(SimpleAgent) == []
    end

    test "actions/1 returns the union from all attached slices" do
      assert is_list(AgentInfo.actions(SimpleAgent))
    end
  end

  describe "new/1 + cmd/2 + set/2" do
    test "new/1 seeds the agent slice with schema defaults" do
      agent = SimpleAgent.new()
      assert %Agent{} = agent
      assert agent.agent_module == SimpleAgent
      assert agent.name == "simple_agent"
      # Schema defaults applied under the agent's path
      assert get_in(agent.state, [:domain, :counter]) == 0
      assert get_in(agent.state, [:domain, :status]) == :idle
    end

    test "new/1 accepts user-supplied state and merges over defaults" do
      agent = SimpleAgent.new(state: %{counter: 5})
      assert get_in(agent.state, [:domain, :counter]) == 5
    end

    test "set/2 wraps flat attrs into the path slice" do
      agent = SimpleAgent.new()
      {:ok, agent} = SimpleAgent.set(agent, %{status: :running})
      assert get_in(agent.state, [:domain, :status]) == :running
    end
  end

  describe "signal_routes do … end section" do
    defmodule RouteAgent do
      @moduledoc false
      use Aikido.Agent

      agent do
        name "route_agent"
      end

      signal_routes do
        route "user.created", AikidoTest.PluginTestAction
        route "high.priority", AikidoTest.PluginTestAction, priority: 10
      end
    end

    test "section entries become legacy route_spec tuples" do
      routes = AgentInfo.signal_routes(RouteAgent)
      assert {"user.created", AikidoTest.PluginTestAction} in routes
      assert {"high.priority", AikidoTest.PluginTestAction, 10} in routes
    end
  end

  describe "compile-time errors" do
    test "missing required `name` raises" do
      assert_raise Spark.Error.DslError, fn ->
        defmodule MissingName do
          use Aikido.Agent

          agent do
          end
        end
      end
    end

    test "schema without path warns at compile time" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule SchemaNoPath do
            use Aikido.Agent

            agent do
              name "schema_no_path"

              schema do
                attribute(:counter, :integer, default: 0)
              end
            end
          end
        end)

      assert stderr =~ ~r/`schema:` is set.*but `path:` is not/
    end

    test "path without schema warns at compile time" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule PathNoSchema do
            use Aikido.Agent

            agent do
              name "path_no_schema"
              path :domain
            end
          end
        end)

      assert stderr =~ ~r/`path: :domain` is set.*but `schema:` is not/
    end
  end
end
