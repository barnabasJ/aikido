defmodule AikidoTest.SliceTest do
  use ExUnit.Case, async: true

  describe "compile-time validation" do
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

  describe "accessors" do
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
        description("A test slice")
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

      capabilities do
        capability(:speak)
      end

      requires do
        requires(:config, :token)
      end

      signal_routes do
        route("send", AikidoTest.PluginTestAction)
      end
    end

    alias Aikido.Dsl.Slice.Info, as: SliceInfo

    test "minimal slice exposes name and path via Info" do
      assert Map.get(SliceInfo.slice_options(MinimalSlice), :name) == "minimal"
      assert SliceInfo.actions(MinimalSlice) == [AikidoTest.PluginTestAction]
      assert Map.get(SliceInfo.slice_options(MinimalSlice), :tags) == []
      assert SliceInfo.capabilities(MinimalSlice) == []

      assert SliceInfo.signal_routes(MinimalSlice) == [
               {"minimal.noop", AikidoTest.PluginTestAction}
             ]
    end

    test "full slice exposes every metadata field via Info" do
      assert Map.get(SliceInfo.slice_options(FullSlice), :name) == "full"
      assert Map.get(SliceInfo.slice_options(FullSlice), :description) == "A test slice"
      assert Map.get(SliceInfo.slice_options(FullSlice), :category) == "test"
      assert Map.get(SliceInfo.slice_options(FullSlice), :vsn) == "0.1.0"
      assert Map.get(SliceInfo.slice_options(FullSlice), :tags) == ["a", "b"]
      assert SliceInfo.capabilities(FullSlice) == [:speak]
      assert SliceInfo.requires(FullSlice) == [config: :token]
      assert SliceInfo.signal_routes(FullSlice) == [{"send", AikidoTest.PluginTestAction}]
      assert Aikido.Action.Schema.schema_type(SliceInfo.schema(FullSlice)) == :ash
      assert Aikido.Action.Schema.schema_type(SliceInfo.config_schema(FullSlice)) == :ash
    end
  end

  describe "schema defaults" do
    defmodule SchemaSlice do
      @moduledoc false
      use Aikido.Slice

      slice do
        name("schema")

        schema do
          attribute(:counter, :integer, allow_nil?: false, default: 0)
        end
      end

      signal_routes do
        route("schema.noop", AikidoTest.PluginTestAction)
      end
    end

    defmodule SchemaAgent do
      @moduledoc false
      use Aikido.Agent, default_slices: false

      agent do
        name("schema_agent")
      end

      slices do
        slice(:schema, AikidoTest.SliceTest.SchemaSlice)
      end
    end

    test "Agent.new/1 seeds slice state from the schema's defaults" do
      agent = SchemaAgent.new()
      assert agent.state.schema == %{counter: 0}
    end

    test "per-agent config merges into the slice on top of defaults" do
      defmodule SchemaAgentConfigured do
        @moduledoc false
        use Aikido.Agent, default_slices: false

        agent do
          name("schema_agent_configured")
        end

        slices do
          slice(:schema, AikidoTest.SliceTest.SchemaSlice, options: [counter: 42])
        end
      end

      agent = SchemaAgentConfigured.new()
      assert agent.state.schema == %{counter: 42}
    end
  end
end
