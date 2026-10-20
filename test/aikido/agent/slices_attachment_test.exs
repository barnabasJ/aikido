defmodule AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "simple_slice"

    schema do
      attribute :counter, :integer, allow_nil?: false, default: 0

      attribute :label, :string,
        allow_nil?: false,
        default: "default",
        constraints: [trim?: false, allow_empty?: true]
    end

    route "simple.noop", {AikidoTest.TestActions, :plugin_test_action}
  end
end

defmodule AikidoTest.Agent.SlicesAttachmentTest.RoutedSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "routed_slice"

    schema do
      attribute :count, :integer, allow_nil?: false, default: 0
    end

    route "absolute.path.one", {AikidoTest.TestActions, :plugin_test_action}
    route "absolute.path.two", {AikidoTest.TestActions, :plugin_test_action}
  end
end

defmodule AikidoTest.Agent.SlicesAttachmentTest.OtherSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "other_slice"

    schema do
      attribute :value, :term, allow_nil?: true
    end

    route "other.noop", {AikidoTest.TestActions, :plugin_test_action}
  end
end

defmodule AikidoTest.Agent.SlicesAttachmentTest.NotASlice do
  @moduledoc false
end

defmodule AikidoTest.Agent.SlicesAttachmentTest do
  use ExUnit.Case, async: true

  describe("bare slice attachment") do
    test "use Aikido.Agent, slices: [SomeSlice] mounts the slice at its path() with seeded defaults" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentBareSlice do
        use Aikido.Agent

        agent do
          name "bare_slice_agent"
          slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice
        end
      end

      agent = AikidoTest.Agent.SlicesAttachmentTest.AgentBareSlice.initialize!()
      assert %{counter: 0, label: "default"} = agent.state.simple

      assert AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Agent.SlicesAttachmentTest.AgentBareSlice
             )
    end

    test "use Aikido.Agent, slices: [{SomeSlice, key: value}] seeds the config into slice state" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentConfiguredSlice do
        use Aikido.Agent

        agent do
          name "configured_slice_agent"

          slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice,
            options: [counter: 42, label: "from_config"]
        end
      end

      agent = AikidoTest.Agent.SlicesAttachmentTest.AgentConfiguredSlice.initialize!()
      assert %{counter: 42, label: "from_config"} = agent.state.simple
    end

    test "slice config in keyword form is also accepted" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentKeywordSlice do
        use Aikido.Agent

        agent do
          name "keyword_slice_agent"
          slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice, options: [counter: 7]
        end
      end

      agent = AikidoTest.Agent.SlicesAttachmentTest.AgentKeywordSlice.initialize!()
      assert agent.state.simple.counter == 7
    end

    test "slice's signal_routes register at the agent with absolute paths (no prefix)" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentRoutedSlice do
        use Aikido.Agent

        agent do
          name "routed_slice_agent"
          slice :routed, AikidoTest.Agent.SlicesAttachmentTest.RoutedSlice
        end
      end

      route_paths =
        AikidoTest.Agent.SlicesAttachmentTest.AgentRoutedSlice
        |> Aikido.Dsl.Agent.Info.routes()
        |> Enum.map(fn {path, _action, _priority} -> path end)

      assert "absolute.path.one" in route_paths
      assert "absolute.path.two" in route_paths
    end

    test "multiple bare slices compose at distinct paths" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentMultipleSlices do
        use Aikido.Agent

        agent do
          name "multiple_slices_agent"
          slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice
          slice :other, AikidoTest.Agent.SlicesAttachmentTest.OtherSlice
        end
      end

      modules =
        Aikido.Dsl.Agent.Info.slices(AikidoTest.Agent.SlicesAttachmentTest.AgentMultipleSlices)

      assert AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice in modules
      assert AikidoTest.Agent.SlicesAttachmentTest.OtherSlice in modules
      agent = AikidoTest.Agent.SlicesAttachmentTest.AgentMultipleSlices.initialize!()
      assert Map.has_key?(agent.state, :simple)
      assert Map.has_key?(agent.state, :other)
    end
  end

  describe("path conflict detection") do
    test "path collision between agent's path: and a slices: entry emits a warning" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentPathConflict do
            use Aikido.Agent

            agent do
              name "path_conflict_agent"
              path :simple
              slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice
            end
          end
        end)

      assert stderr =~ ~r/[Dd]uplicate.*paths/
    end

    test "path collision between two slices: entries emits a warning" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.SimpleSliceDuplicate do
        @moduledoc false
        use Aikido.Slice

        slice do
          name "simple_dup"

          schema do
            attribute :value, :term, allow_nil?: true
          end

          route "simple_dup.noop", {AikidoTest.TestActions, :plugin_test_action}
        end
      end

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentSliceConflict do
            use Aikido.Agent

            agent do
              name "slice_conflict_agent"
              slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice
              slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSliceDuplicate
            end
          end
        end)

      assert stderr =~ "Got duplicate Aikido.Dsl.Agent.SliceMount: simple"
    end
  end

  describe("slices do … end validation") do
    test "non-slice module in `slices do …` raises a clear message" do
      assert_raise Spark.Error.DslError,
                   ~r/Resource slices must be embedded Ash resources/,
                   fn ->
                     defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentRejectsNonSlice do
                       use Aikido.Agent

                       agent do
                         name "rejects_non_slice_agent"
                         slice :bogus, AikidoTest.Agent.SlicesAttachmentTest.NotASlice
                       end
                     end
                   end
    end
  end
end
