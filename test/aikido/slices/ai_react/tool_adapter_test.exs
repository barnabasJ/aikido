defmodule Aikido.Slices.AiReact.ToolAdapterTest do
  use ExUnit.Case, async: true

  alias Aikido.Slices.AiReact.ToolAdapter

  defmodule AshTools do
    use Ash.Resource, data_layer: :embedded

    attributes do
      attribute :count, :integer, public?: true, default: 0
    end

    actions do
      defaults create: :*

      action :echo, :map do
        argument :number, :integer, allow_nil?: false, constraints: [min: 1]

        run fn input, context ->
          {:ok, %{number: input.arguments.number, actor: context.actor}}
        end
      end
    end
  end

  test "Ash tools use the same input shape, casting, context and errors as AshAI" do
    tool = ToolAdapter.from_action({AshTools, :echo})

    assert tool.parameter_schema["properties"]["input"]["properties"]["number"]["type"] ==
             "integer"

    definition = ToolAdapter.ash_tool({AshTools, :echo})

    assert {:ok, _encoded, %{number: 4, actor: %{id: "caller"}}} =
             AshAi.Tools.execute(definition, %{"input" => %{"number" => "4"}}, %{
               actor: %{id: "caller"}
             })

    assert {:error, error} = AshAi.Tools.execute(definition, %{"input" => %{"number" => 0}}, %{})
    assert is_binary(error)
    assert error =~ "number"
  end

  test "Ash create tools reuse AshAI instead of requiring generic actions" do
    assert :ok = ToolAdapter.validate_actions([{AshTools, :create}])
    tool = ToolAdapter.from_action({AshTools, :create})

    assert tool.parameter_schema["properties"]["input"]["properties"]["count"]["type"] ==
             "integer"

    assert {:ok, _encoded, %AshTools{count: 7}} =
             AshAi.Tools.execute(
               ToolAdapter.ash_tool({AshTools, :create}),
               %{"input" => %{"count" => "7"}},
               %{}
             )
  end

  defmodule EmptySchemaAction do
    @moduledoc false
    use Aikido.Action

    action do
      name("empty_action")
      description("An action with no parameters")

      schema do
      end
    end

    @impl true
    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, []}
    end
  end

  defmodule ParamAction do
    @moduledoc false
    use Aikido.Action

    action do
      name("param_action")
      description("An action with parameters")

      schema do
        attribute(:query, :string, description: "Search query", allow_nil?: false)
        attribute(:limit, :integer, description: "Max results", default: 10)
      end
    end

    @impl true
    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, []}
    end
  end

  defmodule StrictAction do
    @moduledoc false
    use Aikido.Action

    action do
      name("strict_action")
      description("An action that explicitly opts into strict mode")

      schema do
        attribute(:value, :string, description: "A value", allow_nil?: false)
      end
    end

    @impl true
    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, []}
    end

    def strict? do
      true
    end
  end

  defmodule NestedSchemaAction do
    @moduledoc false
    use Aikido.Action

    action do
      name("nested_action")
      description("An action with nested objects")

      schema do
        attribute(:name, :string, description: "Name", allow_nil?: false)

        attribute(:config, :map,
          description: "Configuration object",
          allow_nil?: false,
          constraints: [fields: [enabled: [type: :boolean]]]
        )

        attribute(:items, {:array, :map},
          description: "List of objects",
          allow_nil?: false,
          constraints: [items: [fields: [enabled: [type: :boolean]]]]
        )
      end
    end

    @impl true
    def run(_signal, _slice, _opts, _ctx) do
      {:ok, %{}, []}
    end
  end

  describe "from_action/2" do
    test "converts action to ReqLLM.Tool struct" do
      tool = ToolAdapter.from_action(ParamAction)

      assert %ReqLLM.Tool{} = tool
      assert tool.name == "param_action"
      assert tool.description == "An action with parameters"
      assert is_map(tool.parameter_schema)
    end

    test "applies prefix to tool name" do
      tool = ToolAdapter.from_action(ParamAction, prefix: "myapp_")

      assert tool.name == "myapp_param_action"
    end

    test "auto-detects strict: true via strict?/0 callback" do
      tool = ToolAdapter.from_action(StrictAction)

      assert tool.strict == true
    end

    test "defaults to strict: false without strict?/0 callback" do
      tool = ToolAdapter.from_action(ParamAction)

      assert tool.strict == false
    end

    test "respects explicit strict: true override" do
      tool = ToolAdapter.from_action(ParamAction, strict: true)

      assert tool.strict == true
    end

    test "respects explicit strict: false override" do
      tool = ToolAdapter.from_action(StrictAction, strict: false)

      assert tool.strict == false
    end

    test "uses AshAI strict schemas for typed nested objects" do
      tool = ToolAdapter.from_action(NestedSchemaAction)

      schema = tool.parameter_schema

      assert schema["additionalProperties"] == false
      assert schema["properties"]["config"]["additionalProperties"] == false
      assert schema["properties"]["items"]["items"]["additionalProperties"] == false
    end

    test "handles empty schema with valid JSON schema output" do
      tool = ToolAdapter.from_action(EmptySchemaAction)

      assert %ReqLLM.Tool{} = tool
      assert tool.name == "empty_action"

      assert tool.parameter_schema ==
               %{
                 "type" => "object",
                 "properties" => %{},
                 "required" => [],
                 "additionalProperties" => false
               }
    end
  end

  describe "from_actions/2" do
    test "converts list of actions to tools" do
      tools = ToolAdapter.from_actions([EmptySchemaAction, ParamAction])

      assert length(tools) == 2
      assert Enum.all?(tools, &match?(%ReqLLM.Tool{}, &1))
    end

    test "applies filter function" do
      tools =
        ToolAdapter.from_actions(
          [EmptySchemaAction, ParamAction],
          filter: fn mod ->
            Map.get(Aikido.Dsl.Action.Info.action_options(mod), :name) == "param_action"
          end
        )

      assert length(tools) == 1
      assert hd(tools).name == "param_action"
    end

    test "applies prefix to all tools" do
      tools = ToolAdapter.from_actions([EmptySchemaAction, ParamAction], prefix: "v2_")

      assert Enum.all?(tools, fn tool -> String.starts_with?(tool.name, "v2_") end)
    end
  end

  describe "lookup_action/2" do
    test "finds action by tool name" do
      assert {:ok, ParamAction} =
               ToolAdapter.lookup_action("param_action", [EmptySchemaAction, ParamAction])
    end

    test "returns error for unknown tool" do
      assert {:error, :not_found} = ToolAdapter.lookup_action("unknown", [ParamAction])
    end
  end

  describe "lookup_action/3 with prefix" do
    test "finds action by prefixed tool name" do
      assert {:ok, ParamAction} =
               ToolAdapter.lookup_action(
                 "myapp_param_action",
                 [EmptySchemaAction, ParamAction],
                 prefix: "myapp_"
               )
    end

    test "returns error when prefix doesn't match" do
      assert {:error, :not_found} =
               ToolAdapter.lookup_action("param_action", [ParamAction], prefix: "myapp_")
    end

    test "returns error for unknown prefixed tool" do
      assert {:error, :not_found} =
               ToolAdapter.lookup_action("myapp_unknown", [ParamAction], prefix: "myapp_")
    end
  end

  describe "validate_actions/1" do
    defmodule NotAnAction do
      @moduledoc false
      def some_function do
        :ok
      end
    end

    test "returns :ok for valid action modules" do
      assert :ok = ToolAdapter.validate_actions([EmptySchemaAction, ParamAction])
    end

    test "returns error for invalid action module" do
      assert {:error, {:invalid_action, NotAnAction, _reason}} =
               ToolAdapter.validate_actions([ParamAction, NotAnAction])
    end

    test "returns :not_loaded for a module that cannot be loaded" do
      assert {:error, {:invalid_action, This.Module.Does.Not.Exist, :not_loaded}} =
               ToolAdapter.validate_actions([This.Module.Does.Not.Exist])
    end
  end

  describe "to_action_map/1" do
    test "normalizes nil to empty map" do
      assert ToolAdapter.to_action_map(nil) == %{}
    end

    test "normalizes list of modules to name => module map" do
      assert ToolAdapter.to_action_map([ParamAction]) == %{
               Map.get(Aikido.Dsl.Action.Info.action_options(ParamAction), :name) => ParamAction
             }
    end

    test "normalizes single module to map" do
      assert ToolAdapter.to_action_map(ParamAction) == %{
               Map.get(Aikido.Dsl.Action.Info.action_options(ParamAction), :name) => ParamAction
             }
    end

    test "keeps already-normalized maps intact" do
      tools = %{Map.get(Aikido.Dsl.Action.Info.action_options(ParamAction), :name) => ParamAction}
      assert ToolAdapter.to_action_map(tools) == tools
    end

    test "ignores invalid non-module atoms in module lists" do
      assert ToolAdapter.to_action_map([ParamAction, :not_a_module]) == %{
               Map.get(Aikido.Dsl.Action.Info.action_options(ParamAction), :name) => ParamAction
             }
    end

    test "returns empty map for invalid single atom input" do
      assert ToolAdapter.to_action_map(:not_a_module) == %{}
    end
  end

  describe "duplicate detection" do
    defmodule DuplicateNameAction do
      @moduledoc false
      use Aikido.Action

      action do
        name("param_action")
        description("Same name as ParamAction")

        schema do
        end
      end

      @impl true
      def run(_signal, _slice, _opts, _ctx) do
        {:ok, %{}, []}
      end
    end

    test "from_actions raises on duplicate tool names" do
      assert_raise ArgumentError, ~r/duplicate tool names/i, fn ->
        ToolAdapter.from_actions([ParamAction, DuplicateNameAction])
      end
    end

    test "from_actions raises on duplicate names after prefix" do
      defmodule AAction do
        @moduledoc false
        use Aikido.Action

        action do
          name("action")
          description("First action")

          schema do
          end
        end

        @impl true
        def run(_signal, _slice, _opts, _ctx) do
          {:ok, %{}, []}
        end
      end

      defmodule BAction do
        @moduledoc false
        use Aikido.Action

        action do
          name("action")
          description("Second action with same name")

          schema do
          end
        end

        @impl true
        def run(_signal, _slice, _opts, _ctx) do
          {:ok, %{}, []}
        end
      end

      assert_raise ArgumentError, ~r/duplicate tool names/i, fn ->
        ToolAdapter.from_actions([AAction, BAction], prefix: "test_")
      end
    end
  end
end
