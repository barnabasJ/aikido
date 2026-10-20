defmodule Aikido.Dsl.AgentTest.SimpleAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "simple_agent"
    description "Bare agent — no plugins, no slices."
    path :domain

    schema do
      attribute :counter, :integer, default: 0
      attribute :status, :atom, default: :idle
    end
  end
end

defmodule Aikido.Dsl.AgentTest.RouteAgent do
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

defmodule Aikido.Dsl.AgentTest do
  use ExUnit.Case, async: true

  describe("basic accessors (sectioned `agent do … end`)") do
    test "name/1" do
      assert Map.get(Aikido.Dsl.Agent.Info.agent_options(Aikido.Dsl.AgentTest.SimpleAgent), :name) ==
               "simple_agent"
    end

    test "description/1" do
      assert Map.get(
               Aikido.Dsl.Agent.Info.agent_options(Aikido.Dsl.AgentTest.SimpleAgent),
               :description
             ) == "Bare agent — no plugins, no slices."
    end

    test "path/1" do
      assert Map.get(Aikido.Dsl.Agent.Info.agent_options(Aikido.Dsl.AgentTest.SimpleAgent), :path) ==
               :domain
    end

    test "slices/1 / middleware/1 default to framework defaults / empty" do
      assert Aikido.Slices.Memory in Aikido.Dsl.Agent.Info.slices(
               Aikido.Dsl.AgentTest.SimpleAgent
             )

      assert Aikido.Slices.Identity in Aikido.Dsl.Agent.Info.slices(
               Aikido.Dsl.AgentTest.SimpleAgent
             )

      assert Aikido.Slices.Thread in Aikido.Dsl.Agent.Info.slices(
               Aikido.Dsl.AgentTest.SimpleAgent
             )

      assert Aikido.Dsl.Agent.Info.middleware(Aikido.Dsl.AgentTest.SimpleAgent) == []
    end


  end

  describe("agent state helpers") do
    test "initialize seeds the agent slice with schema defaults" do
      agent = Aikido.Dsl.AgentTest.SimpleAgent.initialize!()
      assert %Aikido.Agent{} = agent
      assert agent.agent_module == Aikido.Dsl.AgentTest.SimpleAgent
      assert agent.name == "simple_agent"
      assert get_in(agent.state, [:domain, :counter]) == 0
      assert get_in(agent.state, [:domain, :status]) == :idle
    end

    test "initialize accepts user-supplied state and merges over defaults" do
      agent = Aikido.Dsl.AgentTest.SimpleAgent.initialize!(%{state: %{counter: 5}})
      assert get_in(agent.state, [:domain, :counter]) == 5
    end

    test "embedded actions apply defaults, cast updates and expose validation errors" do
      record = Ash.create!(Aikido.Dsl.AgentTest.SimpleAgent, %{})
      assert record.counter == 0
      updated = Ash.update!(record, %{counter: "5"})
      assert updated.counter == 5
      changeset = Ash.Changeset.for_update(record, :update, %{counter: "invalid"})
      refute changeset.valid?
      assert changeset.errors != []
    end
  end

  describe("signal_routes do … end section") do
    nil

    test "section entries become route_spec tuples" do
      routes = Aikido.Dsl.Agent.Info.signal_routes(Aikido.Dsl.AgentTest.RouteAgent)
      assert {"user.created", AikidoTest.PluginTestAction} in routes
      assert {"high.priority", AikidoTest.PluginTestAction, 10} in routes
    end
  end

  describe("compile-time errors") do
    test "missing required `name` raises" do
      assert_raise Spark.Error.DslError, fn ->
        defmodule Elixir.Aikido.Dsl.AgentTest.MissingName do
          use Aikido.Agent

          agent do
          end
        end
      end
    end

    test "schema without path warns at compile time" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule Elixir.Aikido.Dsl.AgentTest.SchemaNoPath do
            use Aikido.Agent

            agent do
              name "schema_no_path"

              schema do
                attribute :counter, :integer, default: 0
              end
            end
          end
        end)

      assert stderr =~ ~r/`schema:` is set.*but `path:` is not/
    end

    test "path without schema warns at compile time" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule Elixir.Aikido.Dsl.AgentTest.PathNoSchema do
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
