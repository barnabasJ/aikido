defmodule Aikido.Dsl.SliceTest.MinimalSlice do
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

defmodule Aikido.Dsl.SliceTest.FullSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "full"
    description "A full slice"
    category "test"
    vsn "0.1.0"
    tags ["a", "b"]

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

  capabilities do
    capability :speak
  end

  requires do
    requires :config, :token
  end
end

defmodule Aikido.Dsl.SliceTest.SchemaSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "schema_only"

    schema do
      attribute :counter, :integer, allow_nil?: false, default: 0
    end
  end

  signal_routes do
    route "schema_only.noop", AikidoTest.PluginTestAction
  end
end

defmodule Aikido.Dsl.SliceTest.BareSliceAgent do
  @moduledoc false
  use Aikido.Agent, default_slices: false

  agent do
    name "bare_slice_agent"
  end

  slices do
    slice :schema_only, Aikido.Dsl.SliceTest.SchemaSlice
  end
end

defmodule Aikido.Dsl.SliceTest do
  use ExUnit.Case, async: true
  Code.ensure_compiled!(AikidoTest.PluginTestAction)

  describe("slice section accessors") do
    test "minimal slice exposes name, path, schema, and a single route" do
      assert Map.get(
               Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.MinimalSlice),
               :name
             ) == "minimal"

      assert Aikido.Dsl.Slice.Info.actions(Aikido.Dsl.SliceTest.MinimalSlice) == [
               AikidoTest.PluginTestAction
             ]

      assert Map.get(
               Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.MinimalSlice),
               :tags
             ) == []

      assert Aikido.Dsl.Slice.Info.capabilities(Aikido.Dsl.SliceTest.MinimalSlice) == []

      assert Aikido.Dsl.Slice.Info.signal_routes(Aikido.Dsl.SliceTest.MinimalSlice) == [
               {"minimal.noop", AikidoTest.PluginTestAction}
             ]

      assert Aikido.Dsl.Slice.Info.schedules(Aikido.Dsl.SliceTest.MinimalSlice) == []
      assert Aikido.Dsl.Slice.Info.requires(Aikido.Dsl.SliceTest.MinimalSlice) == []

      assert Map.get(
               Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.MinimalSlice),
               :description
             ) == nil

      assert Map.get(
               Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.MinimalSlice),
               :category
             ) == nil

      assert Map.get(Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.MinimalSlice), :vsn) ==
               nil

      assert Map.get(
               Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.MinimalSlice),
               :otp_app
             ) == nil

      assert Ash.Type.ash_type?(Aikido.Dsl.Slice.Info.schema(Aikido.Dsl.SliceTest.MinimalSlice))

      assert Aikido.Dsl.Slice.Info.config_schema(Aikido.Dsl.SliceTest.MinimalSlice) == nil
    end

    test "full slice exposes every metadata field" do
      assert Map.get(Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.FullSlice), :name) ==
               "full"

      assert Map.get(
               Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.FullSlice),
               :description
             ) == "A full slice"

      assert Map.get(
               Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.FullSlice),
               :category
             ) == "test"

      assert Map.get(Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.FullSlice), :vsn) ==
               "0.1.0"

      assert Map.get(Aikido.Dsl.Slice.Info.slice_options(Aikido.Dsl.SliceTest.FullSlice), :tags) ==
               ["a", "b"]

      assert Aikido.Dsl.Slice.Info.actions(Aikido.Dsl.SliceTest.FullSlice) == [
               AikidoTest.PluginTestAction
             ]

      assert Aikido.Dsl.Slice.Info.capabilities(Aikido.Dsl.SliceTest.FullSlice) == [:speak]
      assert Aikido.Dsl.Slice.Info.requires(Aikido.Dsl.SliceTest.FullSlice) == [config: :token]

      assert Aikido.Dsl.Slice.Info.signal_routes(Aikido.Dsl.SliceTest.FullSlice) == [
               {"send", AikidoTest.PluginTestAction}
             ]

      assert Ash.Type.ash_type?(Aikido.Dsl.Slice.Info.schema(Aikido.Dsl.SliceTest.FullSlice))

      assert Aikido.ActionRef.valid?(
               Aikido.Dsl.Slice.Info.config_schema(Aikido.Dsl.SliceTest.FullSlice)
             )
    end

    test "Spark.Dsl.is?(mod, Aikido.Slice) is true for slice modules" do
      assert Aikido.Dsl.Slice in Spark.extensions(Aikido.Dsl.SliceTest.MinimalSlice)
      assert Aikido.Dsl.Slice in Spark.extensions(Aikido.Dsl.SliceTest.FullSlice)
    end
  end

  describe("schema/1 Ash state contracts") do
    test "schema/1 returns the same Ash contract passed into the section" do
      schema = Aikido.Dsl.Slice.Info.schema(Aikido.Dsl.SliceTest.SchemaSlice)
      assert Ash.Type.ash_type?(schema)
      assert {:ok, %{counter: 0}} = Ash.Type.cast_input(schema, %{})
    end

    test "schema/1 returns the slice's declared schema struct" do
      assert Ash.Type.ash_type?(Aikido.Dsl.Slice.Info.schema(Aikido.Dsl.SliceTest.MinimalSlice))
    end
  end

  describe("compile-time validation") do
    test "raises when required `name` is missing" do
      assert_raise Spark.Error.DslError, ~r/required :name option/, fn ->
        Code.compile_string(
          "defmodule Aikido.Dsl.SliceTest.NoName do\n  use Aikido.Slice\n\n  slice do\n  end\nend\n"
        )
      end
    end

    test "raises when name has invalid characters" do
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string(
          "defmodule Aikido.Dsl.SliceTest.BadName do\n  use Aikido.Slice\n\n  slice do\n    name \"has spaces\"\n  end\nend\n"
        )
      end
    end
  end

  describe("agent integration with bare slices") do
    nil

    test "Agent.new/1 seeds slice state from the schema's defaults" do
      agent = Aikido.Dsl.SliceTest.BareSliceAgent.new()
      assert agent.state.schema_only == %{counter: 0}
    end

    test "extensions: [Slice] mounts the slice at its path()" do
      assert Aikido.Dsl.SliceTest.SchemaSlice in Aikido.Dsl.Agent.Info.slices(
               Aikido.Dsl.SliceTest.BareSliceAgent
             )
    end
  end
end
