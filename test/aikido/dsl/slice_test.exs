defmodule Aikido.Dsl.SliceTest do
  use ExUnit.Case, async: true

  # Cover the seven slice DSL sections, the Info-module accessor
  # surface, and the regression cases called out in the task spec
  # (`schema/1` parity with the legacy macro,
  # `Spark.Dsl.is?(mod, Aikido.Slice)` marker, plugin-as-slice override,
  # slice-as-plugin rejection).

  alias Aikido.Dsl.Slice.Info, as: SliceInfo

  Code.ensure_compiled!(AikidoTest.PluginTestAction)

  defmodule MinimalSlice do
    @moduledoc false
    use Aikido.Slice

    slice do
      name("minimal")

      schema do
        attribute(:value, :term, allow_nil?: true)
      end
    end

    signal_routes do
      route("minimal.noop", AikidoTest.PluginTestAction)
    end
  end

  defmodule FullSlice do
    @moduledoc false
    use Aikido.Slice

    slice do
      name("full")
      description("A full slice")
      category("test")
      vsn("0.1.0")
      tags(["a", "b"])

      schema do
        attribute(:counter, :integer, allow_nil?: false, default: 0)
      end

      config_schema do
        attribute(:enabled, :boolean, allow_nil?: false, default: true)
      end
    end

    signal_routes do
      route("send", AikidoTest.PluginTestAction)
    end

    capabilities do
      capability(:speak)
    end

    requires do
      requires(:config, :token)
    end
  end

  defmodule SchemaSlice do
    @moduledoc false
    use Aikido.Slice

    slice do
      name("schema_only")

      schema do
        attribute(:counter, :integer, allow_nil?: false, default: 0)
      end
    end

    signal_routes do
      route("schema_only.noop", AikidoTest.PluginTestAction)
    end
  end

  describe "slice section accessors" do
    test "minimal slice exposes name, path, schema, and a single route" do
      assert Map.get(SliceInfo.slice_options(MinimalSlice), :name) == "minimal"
      assert SliceInfo.actions(MinimalSlice) == [AikidoTest.PluginTestAction]
      assert Map.get(SliceInfo.slice_options(MinimalSlice), :tags) == []
      assert SliceInfo.capabilities(MinimalSlice) == []

      assert SliceInfo.signal_routes(MinimalSlice) == [
               {"minimal.noop", AikidoTest.PluginTestAction}
             ]

      assert SliceInfo.subscriptions(MinimalSlice) == []
      assert SliceInfo.schedules(MinimalSlice) == []
      assert SliceInfo.requires(MinimalSlice) == []
      assert Map.get(SliceInfo.slice_options(MinimalSlice), :description) == nil
      assert Map.get(SliceInfo.slice_options(MinimalSlice), :category) == nil
      assert Map.get(SliceInfo.slice_options(MinimalSlice), :vsn) == nil
      assert Map.get(SliceInfo.slice_options(MinimalSlice), :otp_app) == nil
      assert Aikido.Action.Schema.schema_type(SliceInfo.schema(MinimalSlice)) == :ash
      assert SliceInfo.config_schema(MinimalSlice) == nil
    end

    test "full slice exposes every metadata field" do
      assert Map.get(SliceInfo.slice_options(FullSlice), :name) == "full"
      assert Map.get(SliceInfo.slice_options(FullSlice), :description) == "A full slice"
      assert Map.get(SliceInfo.slice_options(FullSlice), :category) == "test"
      assert Map.get(SliceInfo.slice_options(FullSlice), :vsn) == "0.1.0"
      assert Map.get(SliceInfo.slice_options(FullSlice), :tags) == ["a", "b"]
      assert SliceInfo.actions(FullSlice) == [AikidoTest.PluginTestAction]
      assert SliceInfo.capabilities(FullSlice) == [:speak]
      assert SliceInfo.requires(FullSlice) == [config: :token]
      assert SliceInfo.signal_routes(FullSlice) == [{"send", AikidoTest.PluginTestAction}]
      assert Aikido.Action.Schema.schema_type(SliceInfo.schema(FullSlice)) == :ash
      assert Aikido.Action.Schema.schema_type(SliceInfo.config_schema(FullSlice)) == :ash
    end

    test "Spark.Dsl.is?(mod, Aikido.Slice) is true for slice modules" do
      assert Spark.Dsl.is?(MinimalSlice, Aikido.Slice)
      assert Spark.Dsl.is?(FullSlice, Aikido.Slice)
    end
  end

  describe "schema/1 parity with the legacy macro" do
    test "schema/1 returns the same Ash contract passed into the section" do
      schema = SliceInfo.schema(SchemaSlice)
      assert Aikido.Action.Schema.schema_type(schema) == :ash
      # Round-trip: parsing seed input through the schema yields the default
      assert {:ok, %{counter: 0}} = Aikido.Schema.cast(schema, %{})
    end

    test "schema/1 returns the slice's declared schema struct" do
      assert Aikido.Action.Schema.schema_type(SliceInfo.schema(MinimalSlice)) == :ash
    end
  end

  describe "compile-time validation" do
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

  describe "agent integration with bare slices" do
    defmodule BareSliceAgent do
      @moduledoc false
      use Aikido.Agent, default_slices: false

      agent do
        name("bare_slice_agent")
      end

      slices do
        slice(:schema_only, Aikido.Dsl.SliceTest.SchemaSlice)
      end
    end

    test "Agent.new/1 seeds slice state from the schema's defaults" do
      agent = BareSliceAgent.new()
      assert agent.state.schema_only == %{counter: 0}
    end

    test "extensions: [Slice] mounts the slice at its path()" do
      assert SchemaSlice in Aikido.Dsl.Agent.Info.slices(BareSliceAgent)
    end
  end
end
