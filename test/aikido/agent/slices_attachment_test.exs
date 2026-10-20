defmodule AikidoTest.Agent.SlicesAttachmentTest.SimpleSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "simple_slice"

    schema do
      attribute :counter, :integer do
        description "Counter used to observe routed state transitions."
        allow_nil? false
        default 0
      end

      attribute :label, :string do
        description "Label identifying the directive or fixture result."
        allow_nil? false
        default "default"
        constraints trim?: false, allow_empty?: true
      end
    end

    route "simple.noop", {AikidoTest.TestActions, :noop}
  end
end

defmodule AikidoTest.Agent.SlicesAttachmentTest.RoutedSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "routed_slice"

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        allow_nil? false
        default 0
      end
    end

    route "absolute.path.one", {AikidoTest.TestActions, :noop}
    route "absolute.path.two", {AikidoTest.TestActions, :noop}
  end
end

defmodule AikidoTest.Agent.SlicesAttachmentTest.OtherSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "other_slice"

    schema do
      attribute :value, :term do
        description "Domain value used to verify state transitions and native contracts."
        allow_nil? true
      end
    end

    route "other.noop", {AikidoTest.TestActions, :noop}
  end
end

defmodule AikidoTest.Agent.SlicesAttachmentTest.NotASlice do
  @moduledoc false
end

defmodule AikidoTest.Agent.SlicesAttachmentTest do
  use ExUnit.Case, async: true

  describe("explicit slice mounts") do
    test "an agent-declared mount initializes native slice defaults" do
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

    test "mount options seed the config into slice state" do
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

    test "slice routes register at the agent with absolute paths (no prefix)" do
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

    test "multiple explicit slices compose at distinct paths" do
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
    test "a slice sharing the agent state path emits a warning" do
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

    test "duplicate slice mount paths emit a warning" do
      defmodule Elixir.AikidoTest.Agent.SlicesAttachmentTest.SimpleSliceDuplicate do
        @moduledoc false
        use Aikido.Slice

        slice do
          name "simple_dup"

          schema do
            attribute :value, :term do
              description "Domain value used to verify state transitions and native contracts."
              allow_nil? true
            end
          end

          route "simple_dup.noop", {AikidoTest.TestActions, :noop}
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

  describe("agent slice mount validation") do
    test "mounting a non-slice module raises a clear message" do
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
