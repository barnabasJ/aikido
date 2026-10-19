defmodule AikidoTest.SliceTest.MinimalSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "minimal"

    schema do
      attribute :value, :term, allow_nil?: true
    end
  end

  signal_routes do
    route "minimal.noop", AikidoTest.PluginTestAction
  end
end

defmodule AikidoTest.SliceTest.FullSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "full"
    description "A test slice"

    schema do
      attribute :counter, :integer, allow_nil?: false, default: 0
    end

    config_schema do
      attribute :enabled, :boolean, allow_nil?: false, default: true
    end
  end

  signal_routes do
    route "send", AikidoTest.PluginTestAction
  end
end

defmodule AikidoTest.SliceTest.SchemaSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "schema"

    schema do
      attribute :counter, :integer, allow_nil?: false, default: 0
    end
  end

  signal_routes do
    route "schema.noop", AikidoTest.PluginTestAction
  end
end

defmodule AikidoTest.SliceTest.SchemaAgent do
  @moduledoc false
  use Aikido.Agent, default_slices: false

  agent do
    name "schema_agent"
  end

  slices do
    slice :schema, AikidoTest.SliceTest.SchemaSlice
  end
end

defmodule AikidoTest.SliceTest do
  use ExUnit.Case, async: true

  describe("compile-time validation") do
    test "raises CompileError when name is missing" do
      assert_raise Spark.Error.DslError, ~r/required :name option/, fn ->
        Code.compile_string(
          "defmodule AikidoTest.SliceTest.NoName do\n  use Aikido.Slice\n\n  slice do\n  end\nend\n"
        )
      end
    end

    test "raises CompileError on invalid name" do
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string(
          "defmodule AikidoTest.SliceTest.BadName do\n  use Aikido.Slice\n\n  slice do\n    name \"has spaces\"\n  end\nend\n"
        )
      end
    end
  end

  describe("accessors") do
    nil
    nil
    nil

    test "minimal slice exposes name and path via Info" do
      assert Map.get(
               Aikido.Dsl.Slice.Info.slice_options(AikidoTest.SliceTest.MinimalSlice),
               :name
             ) == "minimal"

      assert Aikido.Dsl.Slice.Info.actions(AikidoTest.SliceTest.MinimalSlice) == [
               AikidoTest.PluginTestAction
             ]

      assert Aikido.Dsl.Slice.Info.signal_routes(AikidoTest.SliceTest.MinimalSlice) == [
               {"minimal.noop", AikidoTest.PluginTestAction}
             ]
    end

    test "full slice exposes every metadata field via Info" do
      assert Map.get(Aikido.Dsl.Slice.Info.slice_options(AikidoTest.SliceTest.FullSlice), :name) ==
               "full"

      assert Map.get(
               Aikido.Dsl.Slice.Info.slice_options(AikidoTest.SliceTest.FullSlice),
               :description
             ) == "A test slice"

      assert Aikido.Dsl.Slice.Info.signal_routes(AikidoTest.SliceTest.FullSlice) == [
               {"send", AikidoTest.PluginTestAction}
             ]

      assert Ash.Type.ash_type?(Aikido.Dsl.Slice.Info.schema(AikidoTest.SliceTest.FullSlice))

      assert Aikido.ActionRef.valid?(
               Aikido.Dsl.Slice.Info.config_schema(AikidoTest.SliceTest.FullSlice)
             )
    end
  end

  describe("schema defaults") do
    nil
    nil

    test "Agent.new/1 seeds slice state from the schema's defaults" do
      agent = AikidoTest.SliceTest.SchemaAgent.initialize!()
      assert agent.state.schema == %{counter: 0}
    end

    test "per-agent config merges into the slice on top of defaults" do
      defmodule Elixir.AikidoTest.SliceTest.SchemaAgentConfigured do
        @moduledoc false
        use Aikido.Agent, default_slices: false

        agent do
          name "schema_agent_configured"
        end

        slices do
          slice :schema, AikidoTest.SliceTest.SchemaSlice, options: [counter: 42]
        end
      end

      agent = AikidoTest.SliceTest.SchemaAgentConfigured.initialize!()
      assert agent.state.schema == %{counter: 42}
    end
  end
end
