defmodule AikidoTest.SliceTest.MinimalSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "minimal"

    schema do
      attribute :value, :term, allow_nil?: true
    end

    route "minimal.noop", {AikidoTest.TestActions, :noop}
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

    route "send", {AikidoTest.TestActions, :noop}
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

    route "schema.noop", {AikidoTest.TestActions, :noop}
  end
end

defmodule AikidoTest.SliceTest.SchemaAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "schema_agent"
    slice :schema, AikidoTest.SliceTest.SchemaSlice
  end
end

defmodule AikidoTest.SliceTest do
  use ExUnit.Case, async: true

  describe("compile-time validation") do
    test "raises CompileError when name is missing" do
      assert_raise Spark.Error.DslError, ~r/required :name option/, fn ->
        Code.compile_string("""
        defmodule AikidoTest.SliceTest.NoName do
          use Aikido.Slice

          slice do
          end
        end
        """)
      end
    end
  end

  describe("accessors") do
    test "minimal slice exposes its name, actions and routes via Info" do
      assert Map.get(
               Aikido.Dsl.Slice.Info.slice_options(AikidoTest.SliceTest.MinimalSlice),
               :name
             ) == "minimal"

      assert Aikido.Dsl.Slice.Info.actions(AikidoTest.SliceTest.MinimalSlice) == [
               {AikidoTest.TestActions, :noop}
             ]

      assert Aikido.Dsl.Slice.Info.signal_routes(AikidoTest.SliceTest.MinimalSlice) == [
               {"minimal.noop", {AikidoTest.TestActions, :noop}}
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
               {"send", {AikidoTest.TestActions, :noop}}
             ]

      assert Ash.Type.ash_type?(Aikido.Dsl.Slice.Info.schema(AikidoTest.SliceTest.FullSlice))

      {resource, action} = Aikido.Dsl.Slice.Info.config_schema(AikidoTest.SliceTest.FullSlice)
      assert Ash.Resource.Info.action(resource, action).type == :action
    end
  end

  describe("schema defaults") do
    test "initialization applies native slice defaults" do
      agent = AikidoTest.SliceTest.SchemaAgent.initialize!()
      assert %{counter: 0} = agent.state.schema
    end

    test "per-agent config merges into the slice on top of defaults" do
      defmodule Elixir.AikidoTest.SliceTest.SchemaAgentConfigured do
        @moduledoc false
        use Aikido.Agent

        agent do
          name "schema_agent_configured"
          slice :schema, AikidoTest.SliceTest.SchemaSlice, options: [counter: 42]
        end
      end

      agent = AikidoTest.SliceTest.SchemaAgentConfigured.initialize!()
      assert %{counter: 42} = agent.state.schema
    end
  end
end
