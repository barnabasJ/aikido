defmodule Aikido.Dsl.AgentOptionalPathTest.NoOpAgent do
  @moduledoc false
  use Aikido.Agent, default_slices: false

  agent do
    name "noop_agent"
    description "No own slice, no extensions, no default slices."
  end
end

defmodule Aikido.Dsl.AgentOptionalPathTest.CompositionAgent do
  @moduledoc false
  use Aikido.Agent, default_slices: %{memory: false, thread: false, identity: false}

  agent do
    name "composition_agent"
    description "Composition over a single contributed slice."
  end

  slices do
    slice :memory, Aikido.Slices.Memory
  end
end

defmodule Aikido.Dsl.AgentOptionalPathTest.PathLessWithDefaults do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "path_less_with_defaults"
  end
end

defmodule Aikido.Dsl.AgentOptionalPathTest.RoutingPathLess do
  @moduledoc false
  use Aikido.Agent, default_slices: false

  agent do
    name "routing_path_less"
  end

  signal_routes do
    route "ping", AikidoTest.PluginTestAction
  end
end

defmodule Aikido.Dsl.AgentOptionalPathTest do
  use ExUnit.Case, async: true

  describe("path-less agent compiles") do
    nil

    test "with no extensions and default_slices disabled" do
      assert Map.get(
               Aikido.Dsl.Agent.Info.agent_options(Aikido.Dsl.AgentOptionalPathTest.NoOpAgent),
               :name
             ) == "noop_agent"

      assert Map.get(
               Aikido.Dsl.Agent.Info.agent_options(Aikido.Dsl.AgentOptionalPathTest.NoOpAgent),
               :path
             ) == nil

      assert Aikido.Dsl.Agent.Info.slice_instances(Aikido.Dsl.AgentOptionalPathTest.NoOpAgent) ==
               []

      assert Aikido.Dsl.Agent.Info.slices(Aikido.Dsl.AgentOptionalPathTest.NoOpAgent) == []
    end

    test "initialize produces an agent with empty state and no nil-keyed entry" do
      agent = Aikido.Dsl.AgentOptionalPathTest.NoOpAgent.initialize!()
      assert %Aikido.Agent{} = agent
      assert agent.state == %{}
      refute Map.has_key?(agent.state, nil)
    end

    test "initialize with user-state preserves keys without wrapping under nil" do
      agent = Aikido.Dsl.AgentOptionalPathTest.NoOpAgent.initialize!(%{state: %{anything: 1}})
      refute Map.has_key?(agent.state, nil)
      assert agent.state[:anything] == 1
    end

    nil

    test "with extensions: [Aikido.Slices.Memory], slice_instances/1 contains the contributed slice" do
      assert Map.get(
               Aikido.Dsl.Agent.Info.agent_options(
                 Aikido.Dsl.AgentOptionalPathTest.CompositionAgent
               ),
               :path
             ) == nil

      paths =
        Enum.map(
          Aikido.Dsl.Agent.Info.slice_instances(
            Aikido.Dsl.AgentOptionalPathTest.CompositionAgent
          ),
          & &1.path
        )

      assert :memory in paths
    end

    test "the agent struct's path-related state stays free of a nil-keyed entry" do
      agent = Aikido.Dsl.AgentOptionalPathTest.CompositionAgent.initialize!()
      refute Map.has_key?(agent.state, nil)
    end
  end

  describe("PathSchemaPair verifier") do
    test "compiles when both `path` and `schema` are set" do
      defmodule Elixir.Aikido.Dsl.AgentOptionalPathTest.BothSet do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "both_set"
          path :domain

          schema do
            attribute :counter, :integer, default: 0
          end
        end
      end

      assert Map.get(
               Aikido.Dsl.Agent.Info.agent_options(Aikido.Dsl.AgentOptionalPathTest.BothSet),
               :path
             ) == :domain
    end

    test "warns when `schema` is set but `path` is not" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule Elixir.Aikido.Dsl.AgentOptionalPathTest.SchemaOnly do
            use Aikido.Agent

            agent do
              name "schema_only"

              schema do
                attribute :counter, :integer, default: 0
              end
            end
          end
        end)

      assert stderr =~ ~r/`schema:` is set.*but `path:` is not/
    end

    test "warns when `path` is set but `schema` is not" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule Elixir.Aikido.Dsl.AgentOptionalPathTest.PathOnly do
            use Aikido.Agent

            agent do
              name "path_only"
              path :domain
            end
          end
        end)

      assert stderr =~ ~r/`path: :domain` is set.*but `schema:` is not/
    end

    test "compiles when neither `path` nor `schema` is set" do
      defmodule Elixir.Aikido.Dsl.AgentOptionalPathTest.NeitherSet do
        @moduledoc false
        use Aikido.Agent, default_slices: false

        agent do
          name "neither_set"
        end
      end

      assert Map.get(
               Aikido.Dsl.Agent.Info.agent_options(Aikido.Dsl.AgentOptionalPathTest.NeitherSet),
               :path
             ) == nil
    end
  end

  describe("default-slices interplay with a path-less agent") do
    nil

    test "default slices are still attached" do
      paths =
        Enum.map(
          Aikido.Dsl.Agent.Info.slice_instances(
            Aikido.Dsl.AgentOptionalPathTest.PathLessWithDefaults
          ),
          & &1.path
        )

      assert :memory in paths
      assert :thread in paths
      assert :identity in paths
    end

    test "no nil-keyed state entry after initialization" do
      agent = Aikido.Dsl.AgentOptionalPathTest.PathLessWithDefaults.initialize!()
      refute Map.has_key?(agent.state, nil)
    end
  end

  describe("signal_routes / schedules sections work without path") do
    nil

    test "signal_routes/1 returns the host-declared routes" do
      assert {"ping", AikidoTest.PluginTestAction} in Aikido.Dsl.Agent.Info.signal_routes(
               Aikido.Dsl.AgentOptionalPathTest.RoutingPathLess
             )
    end
  end
end
