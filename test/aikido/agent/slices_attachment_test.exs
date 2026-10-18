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
  end

  signal_routes do
    route "simple.noop", AikidoTest.PluginTestAction
  end

  capabilities do
    capability :simple
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
  end

  signal_routes do
    route "absolute.path.one", AikidoTest.PluginTestAction
    route "absolute.path.two", AikidoTest.PluginTestAction
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
  end

  signal_routes do
    route "other.noop", AikidoTest.PluginTestAction
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
        use Aikido.Agent, default_slices: false

        agent do
          name "bare_slice_agent"
        end

        slices do
          slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice
        end
      end

      agent = AikidoTest.Agent.SlicesAttachmentTest.AgentBareSlice.new()
      assert agent.state.simple == %{counter: 0, label: "default"}

      assert AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Agent.SlicesAttachmentTest.AgentBareSlice
             )
    end

    test "use Aikido.Agent, slices: [{SomeSlice, key: value}] seeds the config into slice state" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentConfiguredSlice do
        use Aikido.Agent, default_slices: false

        agent do
          name "configured_slice_agent"
        end

        slices do
          slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice,
            options: [counter: 42, label: "from_config"]
        end
      end

      agent = AikidoTest.Agent.SlicesAttachmentTest.AgentConfiguredSlice.new()
      assert agent.state.simple == %{counter: 42, label: "from_config"}
    end

    test "slice config in keyword form is also accepted" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentKeywordSlice do
        use Aikido.Agent, default_slices: false

        agent do
          name "keyword_slice_agent"
        end

        slices do
          slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice, options: [counter: 7]
        end
      end

      agent = AikidoTest.Agent.SlicesAttachmentTest.AgentKeywordSlice.new()
      assert agent.state.simple.counter == 7
    end

    test "slice's signal_routes register at the agent with absolute paths (no prefix)" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentRoutedSlice do
        use Aikido.Agent, default_slices: false

        agent do
          name "routed_slice_agent"
        end

        slices do
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
        use Aikido.Agent, default_slices: false

        agent do
          name "multiple_slices_agent"
        end

        slices do
          slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice
          slice :other, AikidoTest.Agent.SlicesAttachmentTest.OtherSlice
        end
      end

      modules =
        Aikido.Dsl.Agent.Info.slices(AikidoTest.Agent.SlicesAttachmentTest.AgentMultipleSlices)

      assert AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice in modules
      assert AikidoTest.Agent.SlicesAttachmentTest.OtherSlice in modules
      agent = AikidoTest.Agent.SlicesAttachmentTest.AgentMultipleSlices.new()
      assert Map.has_key?(agent.state, :simple)
      assert Map.has_key?(agent.state, :other)
    end

    test "slice capabilities are aggregated" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentSliceCaps do
        use Aikido.Agent, default_slices: false

        agent do
          name "slice_caps_agent"
        end

        slices do
          slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice
        end
      end

      assert :simple in Aikido.Dsl.Agent.Info.capabilities(
               AikidoTest.Agent.SlicesAttachmentTest.AgentSliceCaps
             )
    end
  end

  describe("path conflict detection") do
    test "path collision between agent's path: and a slices: entry emits a warning" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentPathConflict do
            use Aikido.Agent, default_slices: false

            agent do
              name "path_conflict_agent"
              path :simple
            end

            slices do
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
        end

        signal_routes do
          route "simple_dup.noop", AikidoTest.PluginTestAction
        end
      end

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentSliceConflict do
            use Aikido.Agent, default_slices: false

            agent do
              name "slice_conflict_agent"
            end

            slices do
              slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice
              slice :simple, AikidoTest.Agent.SlicesAttachmentTest.SimpleSliceDuplicate
            end
          end
        end)

      assert stderr =~ ~r/[Dd]uplicate.*paths/
    end
  end

  describe("slices do … end validation") do
    test "non-slice module in `slices do …` raises a clear message" do
      assert_raise RuntimeError,
                   ~r/is not a slice resource using `Aikido\.Ash\.Slice`/,
                   fn ->
                     defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentRejectsNonSlice do
                       use Aikido.Agent, default_slices: false

                       agent do
                         name "rejects_non_slice_agent"
                       end

                       slices do
                         slice :bogus, AikidoTest.Agent.SlicesAttachmentTest.NotASlice
                       end
                     end
                   end
    end
  end

  describe("renamed framework singletons") do
    test "Aikido.Slices.Identity attaches via the default-slices path" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.AgentDefaultSlices do
        use Aikido.Agent

        agent do
          name "default_slices_agent"
        end
      end

      modules =
        Aikido.Dsl.Agent.Info.slices(AikidoTest.Agent.SlicesAttachmentTest.AgentDefaultSlices)

      assert Aikido.Slices.Identity in modules
      assert Aikido.Slices.Memory in modules
      assert Aikido.Slices.Thread in modules
    end
  end
end
