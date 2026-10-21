defmodule AikidoTest.SliceTest.MinimalSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "minimal"

    schema do
      attribute :value, :term do
        description "Domain value used to verify state transitions and native contracts."
        allow_nil? true
      end
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
      attribute :counter, :integer do
        description "Counter used to observe routed state transitions."
        allow_nil? false
        default 0
      end
    end

    config_schema do
      attribute :enabled, :boolean do
        description "Boolean option used to verify native default application."
        allow_nil? false
        default true
      end
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
      attribute :counter, :integer do
        description "Counter used to observe routed state transitions."
        allow_nil? false
        default 0
      end
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

defmodule AikidoTest.SliceTest.RequiredConfigSlice do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "required_config"
    otp_app :aikido

    config_schema do
      attribute :attempts, :integer do
        description "Positive attempt limit required by the slice configuration."
        allow_nil? false
        constraints min: 1
      end

      attribute :label, :string do
        description "Label identifying the directive or fixture result."
        default {__MODULE__, :default_label, []}
      end

      attribute :optional, :string do
        description "Optional value used to verify native default handling."
      end
    end
  end

  def default_label, do: "worker"
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
               Aikido.Slice.Info.slice_options(AikidoTest.SliceTest.MinimalSlice),
               :name
             ) == "minimal"

      assert Aikido.Slice.Info.actions(AikidoTest.SliceTest.MinimalSlice) == [
               {AikidoTest.TestActions, :noop}
             ]

      assert Aikido.Slice.Info.signal_routes(AikidoTest.SliceTest.MinimalSlice) == [
               {"minimal.noop", {AikidoTest.TestActions, :noop}}
             ]
    end

    test "full slice exposes every metadata field via Info" do
      assert Map.get(Aikido.Slice.Info.slice_options(AikidoTest.SliceTest.FullSlice), :name) ==
               "full"

      assert Map.get(
               Aikido.Slice.Info.slice_options(AikidoTest.SliceTest.FullSlice),
               :description
             ) == "A test slice"

      assert Aikido.Slice.Info.signal_routes(AikidoTest.SliceTest.FullSlice) == [
               {"send", {AikidoTest.TestActions, :noop}}
             ]

      assert Ash.Type.ash_type?(AikidoTest.SliceTest.FullSlice)

      assert [%Ash.Resource.Attribute{name: :enabled}] =
               Aikido.Slice.Info.config_schema(AikidoTest.SliceTest.FullSlice)

      refute Ash.Resource.Info.action(AikidoTest.SliceTest.FullSlice, :__aikido_config__)
    end
  end

  describe "configuration casting" do
    test "applies defaults without executing an action" do
      assert {:ok, %{enabled: true}} =
               Aikido.Slice.Config.resolve_config(AikidoTest.SliceTest.FullSlice)
    end

    test "casts supplied values and rejects explicitly forbidden nil" do
      assert {:ok, %{enabled: false}} =
               Aikido.Slice.Config.resolve_config(AikidoTest.SliceTest.FullSlice, %{
                 "enabled" => "false"
               })

      assert {:error, %Ash.Error.Changes.InvalidAttribute{field: :enabled}} =
               Aikido.Slice.Config.resolve_config(AikidoTest.SliceTest.FullSlice, %{
                 enabled: nil
               })
    end

    test "rejects invalid typed values" do
      assert {:error, _error} =
               Aikido.Slice.Config.resolve_config(AikidoTest.SliceTest.FullSlice, %{
                 enabled: "not-a-boolean"
               })
    end

    test "enforces required fields and Ash constraints" do
      assert {:error, %Ash.Error.Changes.InvalidAttribute{field: :attempts}} =
               Aikido.Slice.Config.resolve_config(AikidoTest.SliceTest.RequiredConfigSlice)

      assert {:error, %Ash.Error.Changes.InvalidAttribute{field: :attempts}} =
               Aikido.Slice.Config.resolve_config(AikidoTest.SliceTest.RequiredConfigSlice, %{
                 attempts: 0
               })

      assert {:ok, %{attempts: 2, label: "worker", optional: nil}} =
               Aikido.Slice.Config.resolve_config(AikidoTest.SliceTest.RequiredConfigSlice, %{
                 attempts: "2"
               })
    end

    test "mount overrides take precedence over application configuration" do
      resource = AikidoTest.SliceTest.RequiredConfigSlice
      previous = Application.fetch_env(:aikido, resource)
      Application.put_env(:aikido, resource, attempts: 3, label: "application")

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:aikido, resource, value)
          :error -> Application.delete_env(:aikido, resource)
        end
      end)

      assert {:ok, %{attempts: 3, label: "application"}} =
               Aikido.Slice.Config.resolve_config(resource)

      assert {:ok, %{attempts: 5, label: "application"}} =
               Aikido.Slice.Config.resolve_config(resource, %{attempts: 5})
    end

    test "preserves unstructured configuration for a slice without a config schema" do
      assert {:ok, %{custom: "value"}} =
               Aikido.Slice.Config.resolve_config(AikidoTest.SliceTest.MinimalSlice, %{
                 custom: "value"
               })
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
